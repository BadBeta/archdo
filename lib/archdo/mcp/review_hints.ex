defmodule Archdo.Mcp.ReviewHints do
  @moduledoc false

  # Maps static findings to deeper review questions the LLM should investigate,
  # AND provides structured fix patterns for each confirmed issue.
  #
  # Each investigation item has:
  #   - questions: what to look for when reading the code
  #   - fixes: if the investigation confirms the issue, here's exactly how to fix it
  #
  # This is the bridge between "what the code looks like" (Layer 1) and
  # "what to do about what it means" (Layer 2).

  alias Archdo.Diagnostic

  @doc """
  Given a list of diagnostics, produce a structured review plan with
  investigation items AND actionable fixes for each confirmed issue.
  """
  def generate(diagnostics, opts \\ []) do
    project_hints = project_level_hints(diagnostics, opts)

    finding_hints =
      diagnostics
      |> Enum.flat_map(&hints_for_finding/1)
      |> deduplicate()

    Enum.sort_by(project_hints ++ finding_hints, & &1.priority)
  end

  # ──────────────────────────── project-level hints ────────────────────────────

  defp project_level_hints(diagnostics, opts) do
    hints = []
    paths = Keyword.get(opts, :paths, [])

    otp_count = Enum.count(diagnostics, &String.starts_with?(&1.rule_id, "5."))

    hints =
      if otp_count >= 3 do
        [
          %{
            category: "Supervision Tree Architecture",
            priority: 1,
            triggered_by: "#{otp_count} OTP findings detected",
            files: find_files(diagnostics, ["application.ex", "supervisor.ex"]),
            investigate: [
              %{
                question:
                  "Are there children started in multiple places (application.ex AND a custom supervisor)?",
                if_confirmed:
                  "Consolidate into one supervisor. Either have application.ex start only the top-level supervisor, or remove the custom supervisor and list all children in application.ex. Name collisions from double-starting crash at boot.",
                example: """
                ```elixir
                # application.ex — start ONLY the top-level supervisor
                children = [MyApp.Supervisor]
                Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Application)

                # MyApp.Supervisor — owns all subsystem supervisors
                children = [MyApp.Camera.Supervisor, MyApp.Audio.Supervisor, ...]
                Supervisor.init(children, strategy: :one_for_one)
                ```
                """
              },
              %{
                question:
                  "Does the restart strategy match the actual dependency relationships between children?",
                if_confirmed:
                  "Change the strategy: use :one_for_one when children are independent, :rest_for_one when later children depend on earlier ones (e.g. Registry before workers), :one_for_all when all children share state (rare). If mixed, split into sub-supervisors with different strategies.",
                example: """
                ```elixir
                # Infrastructure that must start first → :rest_for_one
                children = [
                  MyApp.Registry,          # must exist before workers
                  MyApp.WorkerSupervisor   # workers register in the registry
                ]
                Supervisor.init(children, strategy: :rest_for_one)
                ```
                """
              },
              %{
                question:
                  "Are failure domains isolated? Can a crash in one subsystem bring down an unrelated one?",
                if_confirmed:
                  "Group related processes under dedicated sub-supervisors. Each subsystem gets its own supervisor with its own max_restarts budget. The top-level supervisor only sees the sub-supervisors, not individual workers."
              },
              %{
                question: "Are there processes started outside ANY supervision tree?",
                if_confirmed:
                  "Move them under a supervisor. For fire-and-forget tasks, add {Task.Supervisor, name: MyApp.TaskSupervisor} and use Task.Supervisor.start_child/2. For long-running processes, define a child_spec and add to the appropriate supervisor."
              }
            ]
          }
          | hints
        ]
      else
        hints
      end

    nif_count = Enum.count(diagnostics, &String.starts_with?(&1.rule_id, "11."))

    hints =
      if nif_count >= 1 do
        [
          %{
            category: "Native Code Safety",
            priority: 2,
            triggered_by: "#{nif_count} NIF findings detected",
            files: find_files_by_rule(diagnostics, ["11.1", "11.2", "11.3", "11.4"]),
            investigate: [
              %{
                question:
                  "Are there .unwrap() / .expect() calls on Mutex locks in the Rust NIF? A panic inside a lock guard poisons the Mutex, and every subsequent lock().unwrap() on that Mutex will also panic — crashing the BEAM on every subsequent NIF call.",
                if_confirmed:
                  "Replace `lock().unwrap()` with `lock().unwrap_or_else(|e| e.into_inner())` to recover from poisoned mutexes. Or switch to `parking_lot::Mutex` which does not poison at all. This is the single highest-impact NIF safety fix.",
                example: """
                ```rust
                // BEFORE — one panic poisons the mutex forever
                let guard = self.state.lock().unwrap();

                // AFTER — recovers from poisoned mutex
                let guard = self.state.lock().unwrap_or_else(|e| e.into_inner());

                // BEST — parking_lot::Mutex never poisons
                // Cargo.toml: parking_lot = "0.12"
                use parking_lot::Mutex;
                let guard = self.state.lock(); // infallible
                ```
                """
              },
              %{
                question:
                  "Does the NIF resource type implement Drop? When the BEAM garbage-collects the resource, do native threads stop and OS resources (file descriptors, DMA buffers, sockets) get released?",
                if_confirmed:
                  "Implement Drop for the resource struct. Set a shutdown flag (AtomicBool), join all spawned threads, and close OS handles. Without Drop, threads become orphans that consume CPU and hold kernel resources after the Elixir process dies.",
                example: """
                ```rust
                impl Drop for CameraHandle {
                    fn drop(&mut self) {
                        self.shutdown.store(true, Ordering::SeqCst);
                        if let Some(thread) = self.receiver_thread.take() {
                            let _ = thread.join();
                        }
                        // Close file descriptors, DMA buffers, etc.
                    }
                }
                ```
                """
              },
              %{
                question:
                  "Are there global mutable variables (static mut, lazy_static with Mutex, thread-local) in the native code?",
                if_confirmed:
                  "Move the state into the NIF resource struct so each Elixir process gets its own instance. If global state is genuinely needed (hardware singleton), use a single-writer pattern with Atomic types or a dedicated mutex, and document the thread-safety contract."
              },
              %{
                question:
                  "Do NIF functions that process variable-size input run on dirty schedulers?",
                if_confirmed:
                  "Add `schedule = \"DirtyCpu\"` (Rustler) or `dirty: :cpu` (Zigler) to any NIF that takes binary/list input or runs > 1ms. Without this, the NIF blocks a normal scheduler and thousands of BEAM processes stall."
              }
            ]
          }
          | hints
        ]
      else
        hints
      end

    clone_count = Enum.count(diagnostics, &(&1.rule_id in ["3.1", "3.4"]))

    hints =
      if clone_count >= 3 do
        [
          %{
            category: "Duplication Semantics",
            priority: 3,
            triggered_by: "#{clone_count} code duplication findings",
            files: find_files_by_rule(diagnostics, ["3.1", "3.4"]),
            investigate: [
              %{
                question:
                  "Do the duplicated functions implement the SAME domain concept? Look for subtle formula differences, different constants, or diverged edge-case handling.",
                if_confirmed:
                  "If same concept with identical logic: extract a shared function, parameterize the caller-specific parts, and replace both call sites. If same concept but the formulas DISAGREE: this is a bug — decide which is correct, fix the other, then extract.",
                example: """
                ```elixir
                # BEFORE — duplicated in module_a.ex and module_b.ex
                def compute_score(entity), do: entity.hits * entity.max_hits * @weight

                # AFTER — shared module
                defmodule MyApp.Scoring do
                  def compute_score(entity, weight), do: entity.hits * entity.max_hits * weight
                end
                ```
                """
              },
              %{
                question:
                  "If the duplicates implement DIFFERENT domain concepts that happen to look alike — should they stay separate?",
                if_confirmed:
                  "Leave them separate but rename one or both so the intent is clear. Add a comment explaining why they look similar but are intentionally independent. Add to the freeze baseline so the duplication rule stops nagging."
              }
            ]
          }
          | hints
        ]
      else
        hints
      end

    scattered_count = Enum.count(diagnostics, &(&1.rule_id == "5.17"))

    hints =
      if scattered_count >= 3 do
        [
          %{
            category: "Process API Design",
            priority: 3,
            triggered_by: "#{scattered_count} scattered GenServer interface findings",
            files: Enum.uniq(for d <- diagnostics, d.rule_id == "5.17", do: d.file),
            investigate: [
              %{
                question:
                  "Are facade modules encoding raw GenServer message tuples ({:start_recording, path, opts}) that should be private to the server?",
                if_confirmed:
                  "Add public API functions to the GenServer module itself and have the facade call those. The message protocol stays private, the API is documented, and changes don't ripple to every caller.",
                example: """
                ```elixir
                # In the GenServer module:
                def start_recording(path, opts \\\\ []) do
                  GenServer.call(__MODULE__, {:start_recording, path, opts})
                end

                # In the facade:
                defdelegate start_recording(path, opts), to: MyApp.Camera.Server
                ```
                """
              },
              %{
                question:
                  "Are there modules using :sys.get_state to extract internal GenServer state?",
                if_confirmed:
                  "Replace with a proper public API function on the GenServer: `def get_handle(server), do: GenServer.call(server, :get_handle)`. :sys.get_state blocks the GenServer, breaks encapsulation, and fails silently if the state shape changes."
              }
            ]
          }
          | hints
        ]
      else
        hints
      end

    io_count = Enum.count(diagnostics, &(&1.rule_id in ["4.4", "4.8"]))

    hints =
      if io_count >= 2 do
        [
          %{
            category: "External Dependency Boundaries",
            priority: 4,
            triggered_by: "#{io_count} external IO / mockability findings",
            files: find_files_by_rule(diagnostics, ["4.4", "4.8"]),
            investigate: [
              %{
                question:
                  "Are external service calls made inside GenServer callbacks? This blocks the entire server.",
                if_confirmed:
                  "Move the call to a Task via Task.Supervisor.async_nolink/2 and handle the result in handle_info. Or move the call to the caller (before entering the GenServer) if it doesn't need the server's state."
              },
              %{
                question:
                  "What happens when external calls fail? Is there retry, timeout, or circuit-breaking?",
                if_confirmed:
                  "Add explicit timeouts to every HTTP/external call. For retriable operations, use exponential backoff via Process.send_after. For critical services, consider a circuit breaker (fuse library). Log failures at :warning with enough context to debug."
              },
              %{
                question:
                  "Is there a consistent error shape? Or do some calls raise, some return {:error, _}, some return nil?",
                if_confirmed:
                  "Normalize to {:ok, result} / {:error, reason} at the adapter boundary. Never let external library exceptions leak into domain code — rescue at the adapter and convert to tagged tuples."
              }
            ]
          }
          | hints
        ]
      else
        hints
      end

    anemic_count = Enum.count(diagnostics, &(&1.rule_id == "1.11"))

    hints =
      if anemic_count >= 2 do
        [
          %{
            category: "Bounded Context Design",
            priority: 4,
            triggered_by: "#{anemic_count} anemic context findings",
            files: find_files_by_rule(diagnostics, ["1.11", "4.7"]),
            investigate: [
              %{
                question:
                  "Are there directories with only 1-2 files that could be folded into a parent context?",
                if_confirmed:
                  "Move the files into the parent context. Delete the empty directory. Update aliases in callers. The boundary disappears, the code lives next to its closest collaborators."
              },
              %{
                question:
                  "Are there data types (structs, maps) that flow across context boundaries without going through a public API?",
                if_confirmed:
                  "Add a public function to the owning context that returns the data. Replace direct struct construction with the public API call. This makes the boundary real — the context owns its data shape."
              }
            ]
          }
          | hints
        ]
      else
        hints
      end

    # Always-ask categories with fixes
    hints =
      [
        %{
          category: "Domain Model Integrity",
          priority: 5,
          triggered_by: "always — requires reading the code",
          files: paths,
          investigate: [
            %{
              question:
                "Is the main data type a struct with @enforce_keys, or a raw map that could silently have missing/extra keys?",
              if_confirmed:
                "Define a struct: `defstruct @enforce_keys ~w(field1 field2)a ++ [optional: nil]`. Add a `new/1` constructor that validates. Replace raw map construction with the constructor. The compiler catches missing keys, pattern matching works, and the shape is documented."
            },
            %{
              question:
                "Are domain invariants enforced at the domain layer, or only at the UI/controller layer?",
              if_confirmed:
                "Move the validation to the domain module (changeset, constructor function, or guard). The UI can still validate for UX, but the domain MUST enforce — otherwise a direct function call bypasses all checks.",
              example: """
              ```elixir
              # Domain enforces:
              def set_production(game, city_id, unit_type) do
                city = find_city(game, city_id)
                if unit_type in [:battleship, :carrier] and not coastal?(city) do
                  {:error, :not_coastal}
                else
                  {:ok, %{game | ...}}
                end
              end
              ```
              """
            },
            %{
              question:
                "Is randomness (:rand) called directly, making the code non-deterministic and untestable?",
              if_confirmed:
                "Inject the random source: add a `random_fn \\\\ &:rand.uniform/0` parameter or seed :rand per-session with a known seed. Tests pass a deterministic function; production uses the default.",
              example: """
              ```elixir
              def resolve_combat(attacker, defender, opts \\\\ []) do
                random = Keyword.get(opts, :random, &:rand.uniform/0)
                if random.() > 0.5, do: :hit, else: :miss
              end

              # Test:
              assert :hit == resolve_combat(a, d, random: fn -> 0.9 end)
              ```
              """
            },
            %{
              question:
                "Are there processes that hold the ONLY copy of important state with no persistence?",
              if_confirmed:
                "Either persist the state (ETS with heir, DETS, database, or periodic snapshots to disk) or document that loss on crash is acceptable. For LiveView: move game/session state to a GenServer or ETS so it survives reconnection."
            }
          ]
        },
        %{
          category: "Error Handling & Resource Cleanup",
          priority: 6,
          triggered_by: "always — requires reading the code",
          files: paths,
          investigate: [
            %{
              question: "Are there bare `rescue _ ->` blocks that swallow errors silently?",
              if_confirmed:
                "At minimum, log the error: `rescue e -> Logger.warning(\"...: \#{inspect(e)}\"); default_value`. Better: let it crash if there's a supervisor, or return {:error, reason} so the caller can decide."
            },
            %{
              question:
                "Are temp files / OS resources cleaned up on error paths, not just success paths?",
              if_confirmed:
                "Use a try/after block or a with chain with a cleanup function in the else clause. The pattern: create resource → try do work after cleanup end.",
              example: """
              ```elixir
              {:ok, path} = Temp.path()
              try do
                File.write!(path, content)
                process(path)
              after
                File.rm(path)
              end
              ```
              """
            },
            %{
              question:
                "Are Port / System.cmd processes cleaned up when the parent dies? Do OS processes outlive the BEAM?",
              if_confirmed:
                "Use MuonTrap.Daemon instead of Port.open for long-running OS processes — it ensures the OS process is killed when the Elixir process dies. For short commands, MuonTrap.cmd/3 adds timeout and cleanup. Never use bare System.cmd for commands that might hang."
            }
          ]
        },
        %{
          category: "Concurrency & Process Lifecycle",
          priority: 6,
          triggered_by: "always — requires reading the code",
          files: paths,
          investigate: [
            %{
              question:
                "Are there GenServer callbacks that block on slow work (HTTP, file I/O, device access)?",
              if_confirmed:
                "Offload to a Task: `Task.Supervisor.async_nolink(MySupervisor, fn -> slow_work() end)`. Return {:noreply, state} immediately. Handle the result in handle_info({ref, result}, state). The GenServer stays responsive.",
              example: """
              ```elixir
              def handle_call(:fetch, from, state) do
                Task.Supervisor.async_nolink(MyApp.TaskSupervisor, fn ->
                  ExternalService.fetch()
                end)
                {:noreply, Map.put(state, :pending, from)}
              end

              def handle_info({ref, result}, %{pending: from} = state) do
                Process.demonitor(ref, [:flush])
                GenServer.reply(from, result)
                {:noreply, Map.delete(state, :pending)}
              end
              ```
              """
            },
            %{
              question:
                "Are there init/1 functions that block on external resources (network, device, Wayland socket)?",
              if_confirmed:
                "Move blocking work to handle_continue/2: `def init(args), do: {:ok, initial_state, {:continue, :setup}}`. The supervisor finishes starting immediately; the GenServer does the slow work as its first message.",
              example: """
              ```elixir
              def init(args) do
                {:ok, %{status: :initializing}, {:continue, :connect}}
              end

              def handle_continue(:connect, state) do
                case connect_to_device() do
                  {:ok, handle} -> {:noreply, %{state | status: :connected, handle: handle}}
                  {:error, _} -> {:noreply, %{state | status: :disconnected}, {:continue, {:retry, 1}}}
                end
              end
              ```
              """
            },
            %{
              question:
                "Are there operations serialized through a single GenServer that could be parallelized (bottleneck)?",
              if_confirmed:
                "Options: (1) Use ETS for read-heavy lookups — no GenServer needed. (2) Use DynamicSupervisor + Registry for per-entity processes. (3) Use PartitionSupervisor to fan across N workers. The right choice depends on whether the serialization is for correctness (keep it) or accident (remove it)."
            },
            %{
              question:
                "Is there a health-check or watchdog for critical external connections (camera, device, network)?",
              if_confirmed:
                "Add a watchdog GenServer that periodically checks the connection (ping, heartbeat, or data-flow monitoring). On failure, trigger recovery: restart the connection process via the supervisor, or transition to a degraded state and retry with backoff.",
              example: """
              ```elixir
              def init(_) do
                :timer.send_interval(5_000, :health_check)
                {:ok, %{consecutive_failures: 0}}
              end

              def handle_info(:health_check, state) do
                case check_connection() do
                  :ok -> {:noreply, %{state | consecutive_failures: 0}}
                  :error ->
                    failures = state.consecutive_failures + 1
                    if failures >= 3, do: trigger_recovery()
                    {:noreply, %{state | consecutive_failures: failures}}
                end
              end
              ```
              """
            }
          ]
        }
      ] ++ hints

    hints
  end

  # ──────────────────────── per-finding contextual hints ───────────────────────

  defp hints_for_finding(%Diagnostic{rule_id: "5.1"} = d) do
    [
      %{
        category: "Resource Leak Risk",
        priority: 2,
        triggered_by: "5.1 bare spawn at #{Path.basename(d.file)}:#{d.line}",
        files: [d.file],
        investigate: [
          %{
            question:
              "Does the spawned function allocate OS resources (file descriptors, ports, DMA buffers, network sockets)?",
            if_confirmed:
              "Replace spawn with Task.Supervisor.start_child under a supervised Task.Supervisor. If the spawned work holds OS resources, implement cleanup in a try/after block inside the task function. For long-lived work, use a proper GenServer under a supervisor with terminate/2 for cleanup."
          },
          %{
            question: "If the parent crashes, does the spawned process become an orphan?",
            if_confirmed:
              "Use spawn_link (crash together) or spawn_monitor (parent gets notified). Best: Task.Supervisor.start_child which gives you supervision, logging, and clean shutdown."
          }
        ]
      }
    ]
  end

  defp hints_for_finding(%Diagnostic{rule_id: "5.20"} = d) do
    [
      %{
        category: "Incomplete Monitor Pattern",
        priority: 3,
        triggered_by: "5.20 monitor without handler at #{Path.basename(d.file)}:#{d.line}",
        files: [d.file],
        investigate: [
          %{
            question:
              "Does the module also send messages via Process.send_after that lack handlers?",
            if_confirmed:
              "Add handle_info clauses for every message type the module sends to itself. Common companion bug: send_after(:force_kill, ...) without a handle_info({:force_kill, _}, state) clause — the force-kill never fires."
          },
          %{
            question:
              "What GenServer state references the monitored process? Does it become stale (dangling pid, stale ref) when the process dies?",
            if_confirmed:
              "Add a handle_info({:DOWN, ref, :process, pid, reason}, state) clause that cleans up the stale references: remove the pid from state, demonitor the ref with [:flush], and decide whether to restart the monitored process or transition to a degraded state."
          }
        ]
      }
    ]
  end

  defp hints_for_finding(%Diagnostic{rule_id: "3.1", context: ctx} = d) do
    [
      %{
        category: "Clone Semantic Mismatch",
        priority: 3,
        triggered_by: "3.1 clone at #{Path.basename(d.file)}:#{d.line}",
        files: [d.file | extract_clone_files(ctx)],
        investigate: [
          %{
            question:
              "Read both copies. Do they compute the same thing? Look for subtle differences in constants, edge cases, or formula.",
            if_confirmed:
              "If identical: extract into a shared module function. If they DISAGREE on the formula: one of them is a bug — decide which is correct based on the domain, fix the other, THEN extract the shared version."
          },
          %{
            question: "Are both copies actively used, or is one dead code from a copy-paste?",
            if_confirmed:
              "If dead code: delete it. If both are used: check that callers get the behavior they expect. If the copies have drifted, the callers may be getting wrong results without knowing."
          }
        ]
      }
    ]
  end

  defp hints_for_finding(%Diagnostic{rule_id: "5.8"} = d) do
    [
      %{
        category: "Startup Blocking",
        priority: 3,
        triggered_by: "5.8 blocking init at #{Path.basename(d.file)}:#{d.line}",
        files: [d.file],
        investigate: [
          %{
            question:
              "Is this GenServer early in the supervision tree? Does init block on a poll/sleep loop or external resource?",
            if_confirmed:
              "Move to handle_continue: `{:ok, %{}, {:continue, :setup}}`. If the resource may never become available, add a retry with backoff via Process.send_after instead of a blocking loop. Set a maximum retry count and transition to :degraded after exhausting it."
          }
        ]
      }
    ]
  end

  defp hints_for_finding(%Diagnostic{rule_id: "6.1"} = d) do
    [
      %{
        category: "Module Responsibility",
        priority: 5,
        triggered_by: "6.1 high function count at #{Path.basename(d.file)}",
        files: [d.file],
        investigate: [
          %{
            question:
              "Does this module mix multiple responsibilities (e.g. protocol handling + state management + encoding)?",
            if_confirmed:
              "Split by responsibility: extract a Protocol module, a State module, and an Encoder module. The original module becomes a thin coordinator that delegates to each. Each new module is independently testable."
          }
        ]
      }
    ]
  end

  defp hints_for_finding(%Diagnostic{rule_id: "11.1"} = d) do
    [
      %{
        category: "NIF Safety Deep Dive",
        priority: 2,
        triggered_by: "11.1 NIF without behaviour at #{Path.basename(d.file)}",
        files: [d.file],
        investigate: [
          %{
            question:
              "Read the native source. Are there global mutable variables or shared Mutexes that could poison?",
            if_confirmed:
              "Move state into the NIF resource struct. Replace Mutex::lock().unwrap() with .unwrap_or_else(|e| e.into_inner()) or switch to parking_lot::Mutex. Implement Drop on the resource to clean up threads and OS handles."
          },
          %{
            question: "Does the NIF do I/O (file, network, device access)?",
            if_confirmed:
              "Consider replacing with a Port for I/O-bound work — Ports run in a separate OS process so crashes don't kill the BEAM. If NIF latency is required, at minimum use dirty:io schedulers and audit every panic path."
          }
        ]
      }
    ]
  end

  defp hints_for_finding(_), do: []

  # ──────────────────────────── helpers ────────────────────────────────────────

  defp find_files(diagnostics, patterns) when is_list(patterns) do
    diagnostics
    |> Enum.map(& &1.file)
    |> Enum.filter(fn file -> Enum.any?(patterns, &String.contains?(file, &1)) end)
    |> Enum.uniq()
  end

  defp find_files_by_rule(diagnostics, rule_ids) do
    Enum.uniq(for d <- diagnostics, d.rule_id in rule_ids, do: d.file)
  end

  defp extract_clone_files(%{duplicates: dups}) when is_binary(dups) do
    dups
    |> String.split(", ")
    |> Enum.map(fn entry ->
      case String.split(entry, ":") do
        [file | _] -> file
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp extract_clone_files(_), do: []

  defp deduplicate(hints) do
    Enum.uniq_by(hints, fn h -> {h.category, h.files} end)
  end
end
