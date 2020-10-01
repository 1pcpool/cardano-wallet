# Stack (recommended)

Use [Haskell Stack](https://haskellstack.org/) to build this project:

```
stack build --test --no-run-tests
```

You may need to install the [`libsodium-dev`](https://doc.libsodium.org/installation), `libghc-hsopenssl-dev`, `gmp`, `sqlite` and `systemd` development
libraries for the build to succeed.

# Cabal 

Download [Cabal](https://www.haskell.org/cabal/download.html) to build this project. Currently recommended version: 3.2.0.0

1. Update your `cabal` index (this may take a while):

   ```console
   cabal update
   ```

2. Build the project

   ```console
   cabal install cardano-wallet --install-method=copy --installdir=/usr/local/bin
   ```

### Syncing `stack` and `cabal` dependencies

1. Install [stack2cabal](https://github.com/hasufell/stack2cabal/releases)

2. Run `stack2cabal` to convert the dependencies list from `stack` into a suitable format for `cabal`. 
 
3. Disable tests and benchmarks of local packages
   (those specified via source-repository-package...
   this won't be needed with cabal-3.4 anymore, because it won't treat
   them as local anymore), e.g.

    ```
    package ouroboros-network
      tests: False
      benchmarks: False
    ```

4. Hackage packages in `packages` in `cardano-1.19.x.yaml` or `extra-deps`
   in `stack.yaml`, which are specified as git repositories might
   have different versions than the stack resolver. `stack2cabal`
   cannot pick these up, so these must be adjusted manually (or deleted) in
   `cabal.project.freeze` (at the time of writing: http-client and persistent).

# Nix 

Use the Nix build if:

1. You don't have Haskell development tools installed, but you do have
   Nix installed.
2. You would like to cross-compile a build for Windows, or run the
   tests under Wine.
3. You would like to quickly grab a build of another branch from the
   Hydra cache, without needing to build it yourself.

Follow the instructions in
[iohk-nix/docs/nix.md](https://github.com/input-output-hk/cardano-node/blob/468f52e5a6a2f18a2a89218a849d702481819f0b/doc/getting-started/building-the-node-using-nix.md#building-under-nix)
to install Nix and set up the IOHK binary cache.

To build the wallet for your current platform:

```
nix-build -A cardano-wallet
```

If you have no local changes in your git repo, then this will download
the build from the Hydra cache rather than building locally.

### Cross-compiling with Nix

To build the wallet for Windows, from **Linux**:

```
nix-build release.nix -A x86_64-w64-mingw32.cardano-wallet.x86_64-linux
```

If you're using **macOS**, then change `x86_64-linux` to
`x86_64-darwin`, and enable the cross-building flag (macOS is disabled
by default to reduce the load on CI):

```
nix-build \
    release.nix \
    --arg supportedCrossSystems '["x86_64-darwin"]' \
     -A x86_64-w64-mingw32.cardano-wallet.x86_64-darwin
```

### Building straight from GitHub

To build another branch (replace `master` with the branch name, tag, or commit hash):

```
nix-build https://github.com/input-output-hk/cardano-wallet/archive/master.tar.gz --argstr gitrev master -A cardano-wallet
```

### Navigating Hydra

The Hydra [Jobset page](https://hydra.iohk.io/jobset/Cardano/cardano-wallet#tabs-jobs)
shows all jobs defined in `release.nix`. Some of the release jobs have a download link.

- [Windows](https://hydra.iohk.io/job/Cardano/cardano-wallet/cardano-wallet-win64/latest)
- [macOS](https://hydra.iohk.io/job/Cardano/cardano-wallet/cardano-wallet-macos64/latest)


### Code generation

The Nix build depends on code which is generated from `stack.yaml` and
the Cabal files. If you change these files, then you will probably
need to update the generated files.

To do this, run:

```
./nix/regenerate.sh
```

Then add and commit the files that it creates.

Alternatively, wait for Buildkite to run this same command, and apply
the patch that it produces.

### Haskell.nix and iohk-nix pins

The Nix build also depends on the [Haskell.nix](https://github.com/input-output-hk/haskell.nix) build infrastructure and the
[iohk-nix](https://github.com/input-output-hk/iohk-nix) library of
common code. It may be necessary to update `haskell.nix` and/or `iohk-nix` when moving to a
new Haskell LTS version or adding Hackage dependencies.

To update these to the latest version, run the following command in a `nix-shell`:

```
niv update haskell.nix
niv update iohk-nix
```

Then commit the updated
[sources.json](https://github.com/input-output-hk/cardano-wallet/blob/master/nix/sources.json)
file.


### Cabal+Nix build

Use the Cabal+Nix build if you want to develop with incremental
builds, but also have it automatically download all dependencies.

If you run `nix-shell`, it will start a
[development environment](https://input-output-hk.github.io/haskell.nix/user-guide/development/)
for `cardano-wallet`. This will contain:

- a GHC configured with a package database containing all Haskell package dependencies;
- system library dependencies;
- a Hoogle index and `hoogle` command for searching documentation;
- development tools such as `ghcide`, `hlint`, `stylish-haskell`, and `weeder`;
- the `sqlite3` command; and
- the node backend `jormungandr`, and `jcli`.
- the Byron Reboot/Shelley node backend `cardano-node`

Inside this shell you can use `cabal new-build` and `ghci` for development.

You must always specify the `--project file` [`cabal-nix.project`](https://github.com/input-output-hk/cardano-wallet/blob/master/cabal-nix.project) argument when running Cabal.

```console
$ nix-shell
[nix-shell:~/iohk/cardano-wallet]$ cabal build --project-file=cabal-nix.project --enable-tests --enable-benchmarks all"
```
