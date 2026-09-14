defmodule Foyer.Runner do
  @moduledoc """
  Side-effect boundary: everything foyer does to the outside world goes through
  a runner. The real runner (`Foyer.Runner.System`) shells out; tests inject a
  fake so the core logic is exercised without touching jj or the filesystem.

  A runner must implement:

    * `run/3`             — execute a command, return `{:ok, output} | {:error, {exit, output}}`
    * `dir?/1`            — does this path exist as a directory?
    * `file?/1`           — does this path exist as a regular file?
    * `list_executables/1` — absolute paths of executable regular files in a directory
  """

  @type result :: {:ok, String.t()} | {:error, {integer(), String.t()}}

  @callback run(command :: String.t(), args :: [String.t()], opts :: keyword()) :: result()
  @callback dir?(path :: String.t()) :: boolean()
  @callback file?(path :: String.t()) :: boolean()

  # List the executable regular files directly inside `dir`, as absolute paths
  # sorted by file name. A missing directory yields `[]` — an absent hooks
  # directory is not an error, it just means there is nothing to run. This is
  # how foyer discovers user-global hook scripts without hard-coding a listing
  # of the real filesystem into the core logic.
  @callback list_executables(dir :: String.t()) :: [String.t()]
end
