{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}

-- |
-- Copyright: © 2018-2020 IOHK
-- License: Apache-2.0
--
-- Provides a function to launch cardano-node for /testing/.

module Cardano.Wallet.Shelley.Launch
    ( -- * Integration Launcher
      withCluster
    , withBFTNode
    , withStakePool

    , NetworkConfiguration (..)
    , nodeSocketOption
    , networkConfigurationOption
    , parseGenesisData
    ) where

import Prelude

import Cardano.BM.Data.Severity
    ( Severity (..) )
import Cardano.BM.Trace
    ( Trace )
import Cardano.CLI
    ( optionT )
import Cardano.Config.Shelley.Genesis
    ( ShelleyGenesis )
import Cardano.Launcher
    ( Command (..), ProcessHasExited (..), StdStream (..), withBackendProcess )
import Cardano.Wallet.Logging
    ( trMessageText )
import Cardano.Wallet.Network.Ports
    ( randomUnusedTCPPorts )
import Cardano.Wallet.Primitive.AddressDerivation
    ( NetworkDiscriminant (..) )
import Cardano.Wallet.Primitive.Types
    ( Block (..), NetworkParameters (..), ProtocolMagic (..) )
import Cardano.Wallet.Shelley
    ( SomeNetworkDiscriminant (..) )
import Cardano.Wallet.Shelley.Compatibility
    ( NodeVersionData, fromGenesisData, testnetVersionData )
import Control.Concurrent.Async
    ( wait, withAsync )
import Control.Concurrent.Chan
    ( newChan, readChan, writeChan )
import Control.Exception
    ( SomeException, finally, handle, throwIO )
import Control.Monad
    ( forM, forM_, replicateM, replicateM_, void )
import Control.Monad.Fail
    ( MonadFail )
import Control.Monad.Trans.Except
    ( ExceptT (..) )
import Data.Aeson
    ( eitherDecode, toJSON, (.=) )
import Data.Either
    ( isLeft, isRight )
import Data.Functor
    ( ($>) )
import Data.List
    ( nub, permutations, sort )
import Data.Proxy
    ( Proxy (..) )
import Data.Text
    ( Text )
import Data.Time.Clock
    ( getCurrentTime )
import GHC.TypeLits
    ( SomeNat (..), someNatVal )
import Options.Applicative
    ( Parser, help, long, metavar )
import Ouroboros.Consensus.Shelley.Node
    ( sgNetworkMagic )
import Ouroboros.Consensus.Shelley.Protocol
    ( TPraosStandardCrypto )
import Ouroboros.Network.Magic
    ( NetworkMagic (..) )
import Ouroboros.Network.NodeToClient
    ( NodeToClientVersionData (..), nodeToClientCodecCBORTerm )
import System.Directory
    ( copyFile )
import System.Exit
    ( ExitCode (..) )
import System.FilePath
    ( takeFileName, (</>) )
import System.Info
    ( os )
import System.IO.Temp
    ( withSystemTempDirectory )
import System.Process
    ( readProcess )
import Test.Utils.Paths
    ( getTestData )

import qualified Data.Aeson as Aeson
import qualified Data.ByteString.Lazy as BL
import qualified Data.HashMap.Strict as HM
import qualified Data.Text as T
import qualified Data.Yaml as Yaml

data NetworkConfiguration where
    TestnetConfig
        :: FilePath
        -> NetworkConfiguration

-- | Hand-written as there's no Show instance for 'NodeVersionData'
instance Show NetworkConfiguration where
    show = \case
        TestnetConfig genesisFile ->
            "TestnetConfig " <> show genesisFile

-- | --node-socket=FILE
nodeSocketOption :: Parser FilePath
nodeSocketOption = optionT $ mempty
    <> long "node-socket"
    <> metavar "FILE"
    <> help "Path to the node's domain socket."

-- | --testnet=FILE
networkConfigurationOption :: Parser NetworkConfiguration
networkConfigurationOption =
    TestnetConfig <$> testnetOption
  where
    -- | --testnet=FILE
    testnetOption
        :: Parser FilePath
    testnetOption = optionT $ mempty
        <> long "testnet"
        <> metavar "FILE"
        <> help "Path to the genesis .json file."

someTestnetDiscriminant
    :: ProtocolMagic
    -> (SomeNetworkDiscriminant, NodeVersionData)
someTestnetDiscriminant pm@(ProtocolMagic n) =
    case someNatVal (fromIntegral n) of
        Just (SomeNat proxy) ->
            ( SomeNetworkDiscriminant $ mapProxy proxy
            , testnetVersionData pm
            )
        _ -> error "networkDiscriminantFlag: failed to convert \
            \ProtocolMagic to SomeNat."
  where
    mapProxy :: forall a. Proxy a -> Proxy ('Testnet a)
    mapProxy _proxy = Proxy @('Testnet a)

parseGenesisData
    :: NetworkConfiguration
    -> ExceptT String IO
        (SomeNetworkDiscriminant, NetworkParameters, NodeVersionData, Block)
parseGenesisData = \case
    TestnetConfig genesisFile -> do
        (genesis :: ShelleyGenesis TPraosStandardCrypto)
            <- ExceptT $ eitherDecode <$> BL.readFile genesisFile
        let nm = unNetworkMagic $ sgNetworkMagic genesis
        let (discriminant, vData) =
                someTestnetDiscriminant $ ProtocolMagic $ fromIntegral nm
        let (np, block0) = fromGenesisData genesis
        pure
            ( discriminant
            , np
            , vData
            , block0
            )

--------------------------------------------------------------------------------
-- For Integration
--------------------------------------------------------------------------------

-- | A quick helper to interact with the 'cardano-cli'. Assumes the cardano-cli
-- is available in PATH.
cli :: [String] -> IO String
cli args =
    readProcess "cardano-cli" args stdin
  where
    stdin = ""

-- | Execute an action after starting a cluster of stake pools. The cluster also
-- contains a single BFT node that is pre-configured with keys available in the
-- test data.
--
-- This BFT node is essential in order to bootstrap the chain and allow
-- registering pools. Passing `0` as a number of pool will simply start a single
-- BFT node.
withCluster
    :: Trace IO Text
    -- ^ Trace for subprocess control logging
    -> Severity
    -- ^ Minimal logging severity
    -> Int
    -- ^ How many pools should the cluster spawn.
    -> (FilePath -> Block -> (NetworkParameters, NodeVersionData) -> IO a)
    -- ^ Action to run with the cluster up
    -> IO a
withCluster tr severity n action = do
    ports <- randomUnusedTCPPorts (n + 1)
    withBFTNode tr severity (head $ rotate ports) $ \socket block0 params -> do
        waitGroup <- newChan
        doneGroup <- newChan
        let waitAll   = replicateM  n (readChan waitGroup)
        let cancelAll = replicateM_ n (writeChan doneGroup ())

        let onException :: SomeException -> IO ()
            onException = writeChan waitGroup . Left

        forM_ (init $ rotate ports) $ \(port, peers) -> do
            handle onException $ withAsync
                (withStakePool tr severity (port, peers) $ do
                    writeChan waitGroup $ Right port -- FIXME: register pool
                    readChan doneGroup
                ) wait

        group <- waitAll
        if length (filter isRight group) /= n then do
            cancelAll
            throwIO $ ProcessHasExited
                ("cluster didn't start correctly: " <> show (filter isLeft group))
                (ExitFailure 1)
        else do
            action socket block0 params `finally` cancelAll
  where
    -- | Get permutations of the size (n-1) for a list of n elements, alongside with
    -- the element left aside. `[a]` is really expected to be `Set a`.
    --
    -- >>> rotate [1,2,3]
    -- [(1,[2,3]), (2, [1,3]), (3, [1,2])]
    rotate :: Ord a => [a] -> [(a, [a])]
    rotate = nub . fmap (\(x:xs) -> (x, sort xs)) . permutations

withBFTNode
    :: Trace IO Text
    -- ^ Trace for subprocess control logging
    -> Severity
    -- ^ Minimal logging severity
    -> (Int, [Int])
    -- ^ A list of ports used by peers and this pool.
    -> (FilePath -> Block -> (NetworkParameters, NodeVersionData) -> IO a)
    -- ^ Callback function with genesis parameters
    -> IO a
withBFTNode tr severity (port, peers) action =
    withSystemTempDirectory "stake-pool" $ \dir -> do
        [vrfPrv, kesPrv, opCert] <- forM
            ["node-vrf.skey", "node-kes.skey", "node.opcert"]
            (\f -> copyFile (source </> f) (dir </> f) $> (dir </> f))

        (config, block0, networkParams, versionData) <- genConfig dir severity
        topology <- genTopology dir peers
        let socket = genSocketPath dir

        let args =
                [ "run"
                , "--config", config
                , "--topology", topology
                , "--database-path", dir </> "db"
                , "--socket-path", socket
                , "--port", show port
                , "--shelley-kes-key", kesPrv
                , "--shelley-vrf-key", vrfPrv
                , "--shelley-operational-certificate", opCert
                ]
        let cmd = Command "cardano-node" args (pure ()) Inherit Inherit
        ((either throwIO pure) =<<)
            $ withBackendProcess (trMessageText tr) cmd
            $ action socket block0 (networkParams, versionData)
  where
    source :: FilePath
    source = $(getTestData) </> "cardano-node-shelley"

-- | Start a "stake pool node". The pool will register itself.
withStakePool
    :: Trace IO Text
    -- ^ Trace for subprocess control logging
    -> Severity
    -- ^ Minimal logging severity
    -> (Int, [Int])
    -- ^ A list of ports used by peers and this pool.
    -> IO a
    -- ^ Callback function called once the pool has started.
    -> IO a
withStakePool tr severity (port, peers) action =
    withSystemTempDirectory "stake-pool" $ \dir -> do
        (opPrv, opPub, opCount)   <- genOperatorKeyPair dir
        (vrfPrv, vrfPub) <- genVrfKeyPair dir
        (kesPrv, kesPub) <- genKesKeyPair dir
        opCert <- issueOpCert dir kesPub opPrv opCount
        (config, _, _, _) <- genConfig dir severity
        topology <- genTopology dir peers

        (stakePrv, stakePub) <- genStakeAddrKeyPair dir
        stakeCert <- genStakeCert dir stakePub
        poolCert <- genPoolCert dir opPub vrfPub stakePub
        dlgCert <- genDlgCert dir stakePub opPub

        let args =
                [ "run"
                , "--config", config
                , "--topology", topology
                , "--database-path", dir </> "db"
                , "--socket-path", genSocketPath dir
                , "--port", show port
                , "--shelley-kes-key", kesPrv
                , "--shelley-vrf-key", vrfPrv
                , "--shelley-operational-certificate", opCert
                ]
        let cmd = Command "cardano-node" args (pure ()) Inherit Inherit
        ((either throwIO pure) =<<)
            $ withBackendProcess (trMessageText tr) cmd action

genConfig
    :: FilePath
    -- ^ A top-level directory where to put the configuration.
    -> Severity
    -- ^ Minimum severity level for logging
    -> IO (FilePath, Block, NetworkParameters, NodeVersionData)
genConfig dir severity = do
    -- we need to specify genesis file location every run in tmp
    Yaml.decodeFileThrow (source </> "node.config")
        >>= withObject (addGenesisFilePath (T.pack nodeGenesisFile))
        >>= withObject (addMinSeverity (T.pack $ show severity))
        >>= Yaml.encodeFile (dir </> "node.config")

    Yaml.decodeFileThrow @_ @Aeson.Value (source </> "genesis.yaml")
        >>= withObject updateStartTime
        >>= Aeson.encodeFile nodeGenesisFile

    (genesisData :: ShelleyGenesis TPraosStandardCrypto)
        <- either (error . show) id . eitherDecode <$> BL.readFile nodeGenesisFile

    let (networkParameters, block0) = fromGenesisData genesisData
    let nm = sgNetworkMagic genesisData
    pure
        ( dir </> "node.config"
        , block0
        , networkParameters
        , (NodeToClientVersionData nm, nodeToClientCodecCBORTerm)
        )
  where
    source :: FilePath
    source = $(getTestData) </> "cardano-node-shelley"

    nodeGenesisFile :: FilePath
    nodeGenesisFile = dir </> "genesis.json"

-- | Generate a valid socket path based on the OS.
genSocketPath :: FilePath -> FilePath
genSocketPath dir =
    if os == "mingw32"
    then "\\\\.\\pipe\\" ++ takeFileName dir
    else dir </> "node.socket"

-- | Generate a topology file from a list of peers.
genTopology :: FilePath -> [Int] -> IO FilePath
genTopology dir peers = do
    let file = dir </> "node.topology"
    Aeson.encodeFile file $ Aeson.object [ "Producers" .= map encodePeer peers ]
    pure file
  where
    encodePeer :: Int -> Aeson.Value
    encodePeer port = Aeson.object
        [ "addr"    .= ("127.0.0.1" :: String)
        , "port"    .= port
        , "valency" .= (1 :: Int)
        ]

-- | Create a key pair for a node operator's offline key and a new certificate
-- issue counter
genOperatorKeyPair :: FilePath -> IO (FilePath, FilePath, FilePath)
genOperatorKeyPair dir = do
    let opPub = dir </> "op.pub"
    let opPrv = dir </> "op.prv"
    let opCount = dir </> "op.count"
    void $ cli
        [ "shelley", "node", "key-gen"
        , "--verification-key-file", opPub
        , "--signing-key-file", opPrv
        , "--operational-certificate-issue-counter", opCount
        ]
    pure (opPrv, opPub, opCount)

-- | Create a key pair for a node KES operational key
genKesKeyPair :: FilePath -> IO (FilePath, FilePath)
genKesKeyPair dir = do
    let kesPub = dir </> "kes.pub"
    let kesPrv = dir </> "kes.prv"
    void $ cli
        [ "shelley", "node", "key-gen-KES"
        , "--verification-key-file", kesPub
        , "--signing-key-file", kesPrv
        ]
    pure (kesPrv, kesPub)

-- | Create a key pair for a node VRF operational key
genVrfKeyPair :: FilePath -> IO (FilePath, FilePath)
genVrfKeyPair dir = do
    let vrfPub = dir </> "vrf.pub"
    let vrfPrv = dir </> "vrf.prv"
    void $ cli
        [ "shelley", "node", "key-gen-VRF"
        , "--verification-key-file", vrfPub
        , "--signing-key-file", vrfPrv
        ]
    pure (vrfPrv, vrfPub)

-- | Create a stake address key pair
genStakeAddrKeyPair :: FilePath -> IO (FilePath, FilePath)
genStakeAddrKeyPair dir = do
    let stakePub = dir </> "stake.pub"
    let stakePrv = dir </> "stake.prv"
    void $ cli
        [ "shelley", "stake-address", "key-gen"
        , "--verification-key-file", stakePub
        , "--signing-key-file", stakePrv
        ]
    pure (stakePrv, stakePub)

-- | Issue a node operational certificate
issueOpCert :: FilePath -> FilePath -> FilePath -> FilePath -> IO FilePath
issueOpCert dir kesPub opPrv opCount = do
    let file = dir </> "op.cert"
    void $ cli
        [ "shelley", "node", "issue-op-cert"
        , "--kes-verification-key-file", kesPub
        , "--cold-signing-key-file", opPrv
        , "--operational-certificate-issue-counter-file", opCount
        , "--kes-period", "0"
        , "--out-file", file
        ]
    pure file

-- | Create a stake address registration certificate
genStakeCert :: FilePath -> FilePath -> IO FilePath
genStakeCert dir stakePub = do
    let file = dir </> "stake.cert"
    void $ cli
        [ "shelley", "stake-address", "registration-certificate"
        , "--staking-verification-key-file", stakePub
        , "--out-file", file
        ]
    pure file

-- | Create a stake pool registration certificate
genPoolCert :: FilePath -> FilePath -> FilePath -> FilePath -> IO FilePath
genPoolCert dir opPub vrfPub stakePub = do
    let file = dir </> "pool.cert"
    void $ cli
        [ "shelley", "stake-pool", "registration-certificate"
        , "--cold-verification-key-file", opPub
        , "--vrf-verification-key-file", vrfPub
        , "--pool-pledge", show oneMillionAda
        , "--pool-cost", "0"
        , "--pool-margin", "0.1"
        , "--pool-reward-account-verification-key-file", stakePub
        , "--pool-owner-stake-verification-key-file", stakePub
        , "--mainnet"
        , "--out-file", file
        ]
    pure file
  where
    oneMillionAda :: Integer
    oneMillionAda = 1_000_000_000_000

-- | Create a stake address delegation certificate
genDlgCert :: FilePath -> FilePath -> FilePath -> IO FilePath
genDlgCert dir stakePub opPub = do
    let file = dir </> "dlg.cert"
    void $ cli
        [ "shelley", "stake-address", "delegation-certificate"
        , "--staking-verification-key-file", stakePub
        , "--stake-pool-verification-key-file", opPub
        , "--out-file", file
        ]
    pure file

-- | Add a "systemStart" field in a given object with the current POSIX time as a
-- value.
updateStartTime
    :: Aeson.Object
    -> IO Aeson.Object
updateStartTime m = do
    time <- getCurrentTime
    pure $ HM.insert "systemStart" (toJSON time) m

-- | Add a "GenesisFile" field in a given object with the current path of
-- genesis.json in tmp dir as value.
addGenesisFilePath
    :: Text
    -> Aeson.Object
    -> IO Aeson.Object
addGenesisFilePath path = pure . HM.insert "GenesisFile" (toJSON path)

-- | Add a "minSeverity" field in a given object with the current path of
-- genesis.json in tmp dir as value.
addMinSeverity
    :: Text
    -> Aeson.Object
    -> IO Aeson.Object
addMinSeverity severity = pure . HM.insert "minSeverity" (toJSON severity)

-- | Do something with an a JSON object. Fails if the given JSON value isn't an
-- object.
withObject
    :: MonadFail m
    => (Aeson.Object -> m Aeson.Object)
    -> Aeson.Value
    -> m Aeson.Value
withObject action = \case
    Aeson.Object m -> Aeson.Object <$> action m
    _ -> fail
        "withObject: was given an invalid JSON. Expected an Object but got \
        \something else."
