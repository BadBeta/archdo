defmodule Archdo.RuleTest do
  use ExUnit.Case, async: true

  alias Archdo.Rule

  defmodule WithoutPack do
    @behaviour Archdo.Rule
    @impl true
    def id, do: "TEST.0"
    @impl true
    def description, do: "no pack callback"
    @impl true
    def analyze(_file, _ast, _opts), do: []
  end

  defmodule WithCorePack do
    @behaviour Archdo.Rule
    @impl true
    def id, do: "TEST.1"
    @impl true
    def description, do: "explicit core"
    @impl true
    def analyze(_file, _ast, _opts), do: []
    @impl true
    def pack, do: :core
  end

  defmodule WithComposabilityPack do
    @behaviour Archdo.Rule
    @impl true
    def id, do: "TEST.2"
    @impl true
    def description, do: "ce_composability"
    @impl true
    def analyze(_file, _ast, _opts), do: []
    @impl true
    def pack, do: :ce_composability
  end

  describe "pack_of!/1" do
    test "defaults to :core when the rule does not declare pack/0" do
      assert Rule.pack_of!(WithoutPack) == :core
    end

    test "returns the declared pack when pack/0 is exported" do
      assert Rule.pack_of!(WithCorePack) == :core
      assert Rule.pack_of!(WithComposabilityPack) == :ce_composability
    end

    test "raises when the module does not implement Archdo.Rule" do
      assert_raise ArgumentError, fn -> Rule.pack_of!(:not_a_module) end
    end
  end

  describe "known_packs/0" do
    test "lists every supported pack identifier" do
      packs = Rule.known_packs()
      assert :core in packs
      assert :ce_compliance in packs
      assert :ce_privacy in packs
      assert :ce_composability in packs
    end
  end
end
