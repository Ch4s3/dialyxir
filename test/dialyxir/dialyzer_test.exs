defmodule Dialyxir.DialyzerTest do
  use ExUnit.Case
  alias Dialyxir.Dialyzer

  defmodule StubSuccess do
    def run(_, _), do: {:ok, {"time", [], ""}}
  end

  defmodule StubWarn do
    def run(_, _), do: {:ok, {"time", ["warning 1", "warning 2"], ""}}
  end

  defmodule StubError do
    def run(_, _), do: {:error, "dialyzer failed"}
  end

  defmodule RunnerDialyzerStub do
    def run(args) do
      send(self(), {:dialyzer_run_args, args})
      []
    end
  end

  defmodule RunnerFiltererStub do
    def filter_map(_args), do: %Dialyxir.FilterMap{}

    def filter_warning?(_warning, _filter_map), do: {false, []}

    def filter_legacy_warnings(output), do: output
  end

  setup do
    ansi_enabled = IO.ANSI.enabled?()

    on_exit(fn ->
      Application.put_env(:elixir, :ansi_enabled, ansi_enabled)
    end)
  end

  describe "dialyze/3" do
    import Dialyzer, only: [dialyze: 3]

    test "formatting with no warnings, colors enabled" do
      Application.put_env(:elixir, :ansi_enabled, true)

      {expected_result_code, expected_exit_code, expected_messages} =
        dialyze(nil, StubSuccess, nil)

      assert expected_result_code == :ok
      assert expected_exit_code == 0

      assert expected_messages == [
               "time",
               "",
               [[[[] | "\e[32m"], "done (passed successfully)"] | "\e[0m"]
             ]
    end

    test "formatting with no warnings, colors disabled" do
      Application.put_env(:elixir, :ansi_enabled, false)

      {expected_result_code, expected_exit_code, expected_messages} =
        dialyze(nil, StubSuccess, nil)

      assert expected_result_code == :ok
      assert expected_exit_code == 0
      assert expected_messages == ["time", "", [[], "done (passed successfully)"]]
    end

    test "formatting with warnings, colors enabled" do
      Application.put_env(:elixir, :ansi_enabled, true)

      {expected_result_code, expected_exit_code, expected_messages} = dialyze(nil, StubWarn, nil)

      assert expected_result_code == :warn
      assert expected_exit_code == 2

      assert expected_messages == [
               "time",
               [[[[] | "\e[31m"], "warning 1"] | "\e[0m"],
               [[[[] | "\e[31m"], "warning 2"] | "\e[0m"],
               "",
               [[[[] | "\e[33m"], "done (warnings were emitted)"] | "\e[0m"]
             ]
    end

    test "formatting with warnings, colors disabled" do
      Application.put_env(:elixir, :ansi_enabled, false)

      {expected_result_code, expected_exit_code, expected_messages} = dialyze(nil, StubWarn, nil)

      assert expected_result_code == :warn
      assert expected_exit_code == 2

      assert expected_messages == [
               "time",
               [[], "warning 1"],
               [[], "warning 2"],
               "",
               [[], "done (warnings were emitted)"]
             ]
    end

    test "formatting with errors, colors enabled" do
      Application.put_env(:elixir, :ansi_enabled, true)

      {expected_result_code, expected_exit_code, expected_messages} = dialyze(nil, StubError, nil)

      assert expected_result_code == :error
      assert expected_exit_code == 1
      assert expected_messages == [[[[[] | "\e[31m"], "dialyzer failed"] | "\e[0m"]]
    end

    test "formatting with errors, colors disabled" do
      Application.put_env(:elixir, :ansi_enabled, false)

      {expected_result_code, expected_exit_code, expected_messages} = dialyze(nil, StubError, nil)

      assert expected_result_code == :error
      assert expected_exit_code == 1
      assert expected_messages == [[[], "dialyzer failed"]]
    end
  end

  describe "Runner incremental args" do
    setup do
      Application.put_env(:dialyxir, :dialyzer_module, RunnerDialyzerStub)

      on_exit(fn ->
        Application.delete_env(:dialyxir, :dialyzer_module)
      end)

      :ok
    end

    test "analysis_type is set when incremental flag is present" do
      args = [
        {:check_plt, false},
        {:init_plt, ~c"dummy.plt"},
        {:files, []},
        {:warnings, []},
        {:format, []},
        {:raw, false},
        {:list_unused_filters, false},
        {:ignore_exit_status, false},
        {:quiet_with_result, false},
        {:incremental, true}
      ]

      assert {:ok, {_time, [], ""}} = Dialyxir.Dialyzer.Runner.run(args, RunnerFiltererStub)

      assert_receive {:dialyzer_run_args, final_args}
      assert {:analysis_type, :incremental} in final_args
    end
  end

  describe "maybe_add_macos_ulimit_hint/1" do
    alias Dialyxir.Dialyzer.Runner

    test "returns original message when not a file descriptor error" do
      msg = "some other error message"
      result = Runner.maybe_add_macos_ulimit_hint(msg)
      assert result == msg
    end

    test "adds hint for dialyzer_iplt MD5 computation error on macOS" do
      # Real error format from dialyzer_iplt.erl compute_md5_from_file/1
      msg =
        "Could not compute MD5 for .beam: /path/to/Elixir.MyModule.beam (reason: {file_error,\"/path/to/Elixir.MyModule.beam\",emfile})"

      result = Runner.maybe_add_macos_ulimit_hint(msg)

      case :os.type() do
        {:unix, :darwin} ->
          assert String.contains?(result, "macOS FILE DESCRIPTOR LIMIT")
          assert String.contains?(result, "ulimit -n 1024")
          assert String.contains?(result, msg)

        _ ->
          # On non-macOS, should return original message
          assert result == msg
      end
    end

    test "adds hint for erl_prim_loader file operation error on macOS" do
      # Real error format from erl_prim_loader
      msg =
        "File operation error: emfile. Target: /Users/dev/.asdf/installs/elixir/1.18.4/lib/elixir/ebin/application.beam. Function: get_modules."

      result = Runner.maybe_add_macos_ulimit_hint(msg)

      case :os.type() do
        {:unix, :darwin} ->
          assert String.contains?(result, "macOS FILE DESCRIPTOR LIMIT")
          assert String.contains?(result, "ulimit -n 1024")

        _ ->
          assert result == msg
      end
    end

    test "adds hint for 'too many open files' error on macOS" do
      msg = "Error: too many open files"
      result = Runner.maybe_add_macos_ulimit_hint(msg)

      case :os.type() do
        {:unix, :darwin} ->
          assert String.contains?(result, "macOS FILE DESCRIPTOR LIMIT")
          assert String.contains?(result, "ulimit -n 1024")

        _ ->
          assert result == msg
      end
    end

    test "adds hint for system_limit error on macOS" do
      msg = "system_limit reached"
      result = Runner.maybe_add_macos_ulimit_hint(msg)

      case :os.type() do
        {:unix, :darwin} ->
          assert String.contains?(result, "macOS FILE DESCRIPTOR LIMIT")
          assert String.contains?(result, "ulimit -n 1024")

        _ ->
          assert result == msg
      end
    end

    test "is case-insensitive for error detection" do
      msg = "EMFILE error occurred"
      result = Runner.maybe_add_macos_ulimit_hint(msg)

      case :os.type() do
        {:unix, :darwin} ->
          assert String.contains?(result, "macOS FILE DESCRIPTOR LIMIT")

        _ ->
          assert result == msg
      end
    end

    test "preserves original error message in the hint" do
      # Real error format with full path
      original_msg =
        "Could not compute MD5 for .beam: /Users/dev/project/_build/dev/lib/myapp/ebin/Elixir.MyApp.beam (reason: {file_error,\"/Users/dev/project/_build/dev/lib/myapp/ebin/Elixir.MyApp.beam\",emfile})"

      result = Runner.maybe_add_macos_ulimit_hint(original_msg)

      case :os.type() do
        {:unix, :darwin} ->
          assert String.contains?(result, original_msg)
          assert String.contains?(result, "macOS FILE DESCRIPTOR LIMIT")

        _ ->
          assert result == original_msg
      end
    end
  end
end
