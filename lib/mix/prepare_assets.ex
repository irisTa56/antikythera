# Copyright(c) 2015-2024 ACCESS CO., LTD. All rights reserved.

use Croma

defmodule Mix.Tasks.Antikythera.PrepareAssets do
  @shortdoc "Prepares static assets for your gear"
  @moduledoc """
  #{@shortdoc}.

  This mix task must be called before compilations of the gear if you need asset preparation.
  It ensures all static assets of your gear reside in `priv/static/` directory before compilations of `YourGear.Asset` module.
  Assets in `priv/static/` directory must be uploaded to cloud storage by `mix antikythera_core.upload_new_asset_versions` for serving via CDN if you run the gear on cloud.
  See `Antikythera.Asset` and `Mix.Tasks.AntikytheraCore.UploadNewAssetVersions` for details.

  If your gear uses some kind of preprocessing tools to generate asset files (JS, CSS, etc.),
  you have to set up the supported asset preparation method described in the next section.

  This mix task invokes the preprocessing tools with `ANTIKYTHERA_COMPILE_ENV` environment variable
  (see also `Antikythera.Env`).
  You can use this environment variable to distinguish for which environment current script is running.

  ## Supported Asset Preparation Method

  Asset preparation process is split into 3 steps: package installation step, auditing step and build step.
  If any part of the preparation process resulted in failure (non-zero exit code),
  the whole task will abort and thus auto-deploy will fail.

  - Prerequisite: `package.json` file and `antikythera_prepare_assets` script in it

  Note that if the above prerequisite is not present,
  **the whole asset preparation process will be skipped** since package installation is unnecessary.

  ### Package Installation

  Use [`yarn`](https://yarnpkg.com/en/) if `yarn.lock` file exists, otherwise use `npm install`.

  ### Auditing the packages

  Run `yarn audit` or `npm audit` and abort if one or more critical packages found.

  ### Build using [npm-scripts](https://docs.npmjs.com/misc/scripts)

  - Command: `npm run antikythera_prepare_assets`
  - Within `antikythera_prepare_assets` script, you may execute any asset-related actions such as:
      - Linting
      - Type Checking
      - Testing
      - Compiling/Transpiling
      - Uglifying/Minifying
      - etc...
  - How to organize these actions is up to you. You may use whatever tools available in `npm`,
    such as [`webpack`](https://webpack.js.org/) or [`browserify`](http://browserify.org/).

  #### Note on implementation

  This step is responsible for placing finalized static assets into `priv/static/` directory.

  In old versions of `gear_generator`, Node.js packages that depend on
  [`compass`](http://compass-style.org/) was used by default in generated gear.
  `compass` gem was (and is) globally installed on antikythera jenkins server to enable them.

  However, [`compass` is no longer maintained](https://github.com/Compass/compass/commit/dd74a1cfef478a896d03152b2c2a3b93839d168e).
  We recommend you to consider using alternative SASS/SCSS processor.
  `compass` gem will be kept installed for backward compatibility.
  """

  use Mix.Task
  alias Antikythera.Asset

  @impl true
  def run(args) do
    run_impl(List.first(args) || "undefined")
  end

  defp run_impl(env) do
    if npm_script_available?() do
      install_packages!(env)
      audit_vulnerability(env)
      build_assets!(env)
      dump_asset_file_paths()
    else
      IO.puts("Skipping. Asset preparation is not configured.")

      IO.puts(
        "Define `antikythera_prepare_assets` npm-script if you want antikythera to prepare assets for your gear."
      )
    end
  end

  defp npm_script_available?() do
    with {:ok, json} <- File.read("package.json"),
         {:ok, %{"scripts" => map}} <- Poison.decode(json),
         %{"antikythera_prepare_assets" => cmd} <- map do
      is_binary(cmd)
    else
      _ -> false
    end
  end

  defp install_packages!(env) do
    if File.exists?("yarn.lock") do
      run_command!("yarn", [], env)
    else
      remove_node_modules_if_dependencies_changed!()
      run_command!("npm", ["install"], env)
    end
  end

  defp remove_node_modules_if_dependencies_changed!() do
    case System.get_env("GIT_PREVIOUS_SUCCESSFUL_COMMIT") do
      nil ->
        :ok

      commit ->
        files_to_check = ["package.json", "npm-shrinkwrap.json", "package-lock.json"]
        {_output, status} = System.cmd("git", ["diff", "--quiet", commit, "--" | files_to_check])

        if status == 1 do
          IO.puts(
            "Removing node_modules/ in order to avoid potential issues in npm's dependency resolution."
          )

          File.rm_rf!("node_modules")
        end
    end
  end

  defp audit_vulnerability(env) do
    if File.exists?("yarn.lock") do
      audit_vulnerability_with_yarn(env)
    else
      audit_vulnerability_with_npm(env)
    end
  end

  defp audit_vulnerability_with_yarn(env) do
    # > The exit code will be a mask of the severities.
    # > 16 for CRITICAL
    # https://yarnpkg.com/lang/en/docs/cli/audit/
    {_, status, _} = run_command("yarn", ["audit", "--level", "critical"], env)

    if status >= 16 do
      raise "One or more critical packages are found: #{status}"
    end
  end

  defp audit_vulnerability_with_npm(env) do
    {_, status, _} = run_command("npm", ["audit", "--audit-level", "critical"], env)

    if status != 0 do
      if File.exists?("package-lock.json") || File.exists?("npm-shrinkwrap.json") do
        raise "One or more critical packages are found: #{status}"
      else
        # Failure due to missing lock file.
        raise "No lock file is found."
      end
    end
  end

  defp build_assets!(env) do
    run_command!("npm", ["run", "antikythera_prepare_assets"], env)
  end

  def dump_asset_file_paths() do
    IO.puts("Done. Current assets under priv/static/ directory:")

    case Asset.list_asset_file_paths() do
      [] -> IO.puts("  (No asset files exist)")
      paths -> Enum.each(paths, fn path -> IO.puts("  * " <> path) end)
    end
  end

  defun run_command!(cmd :: v[String.t()], args :: v[[String.t()]], env :: v[String.t()]) ::
          String.t() do
    {output, status, invocation} = run_command(cmd, args, env)

    if status == 0 do
      output
    else
      raise("`#{invocation}` resulted in non-zero exit code: #{status}")
    end
  end

  defun run_command(cmd :: v[String.t()], args :: v[[String.t()]], env :: v[String.t()]) ::
          {String.t(), non_neg_integer, String.t()} do
    invocation = Enum.join([cmd | args], " ")
    IO.puts("$ #{invocation}")

    {output, status} =
      System.cmd(cmd, args, stderr_to_stdout: true, env: %{"ANTIKYTHERA_COMPILE_ENV" => env})

    IO.puts(output)
    {output, status, invocation}
  end
end
