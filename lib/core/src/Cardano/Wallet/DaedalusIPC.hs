{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- |
-- Copyright: © 2018-2020 IOHK
-- License: Apache-2.0
--
-- Provides a mechanism for Daedalus to discover what port the cardano-wallet
-- server is listening on.
--
-- See <https://nodejs.org/api/child_process.html#child_process_child_process_spawn_command_args_options>
-- for more information about the message protocol.
--
-- There are two separate message formats and IO mechanisms, depending on
-- whether the OS is Windows or not. On Windows, a duplex named pipe is used for
-- communication with the parent process. If modifying this code, do not add
-- concurrent sending and receiving of messages. It will get stuck, because
-- asynchronous reading and writing to named pipes is not possible.
--

module Cardano.Wallet.DaedalusIPC
    ( daedalusIPC
    , DaedalusIPCLog(..)
    ) where

import Prelude

import Cardano.BM.Data.Severity
    ( Severity (..) )
import Cardano.BM.Data.Tracer
    ( HasPrivacyAnnotation (..), HasSeverityAnnotation (..), ToObject (..) )
import Control.Concurrent
    ( threadDelay )
import Control.Exception
    ( IOException, catch, tryJust )
import Control.Monad
    ( forever )
import Control.Monad.Trans.Class
    ( lift )
import Control.Monad.Trans.Except
    ( ExceptT, except, runExceptT )
import Control.Tracer
    ( Tracer, traceWith )
import Data.Aeson
    ( FromJSON (..)
    , ToJSON (..)
    , Value (..)
    , eitherDecode
    , encode
    , object
    , withObject
    , (.:)
    , (.=)
    )
import Data.Bifunctor
    ( first )
import Data.Binary.Get
    ( getWord32le, getWord64le )
import Data.Binary.Get.Safe
    ( eitherRunGet )
import Data.Binary.Put
    ( putLazyByteString, putWord32le, putWord64le, runPut )
import Data.Maybe
    ( fromMaybe )
import Data.Text
    ( Text )
import Data.Text.Class
    ( ToText (..) )
import Data.Word
    ( Word32, Word64 )
import GHC.Generics
    ( Generic )
import GHC.IO.Handle.FD
    ( fdToHandle )
import System.Environment
    ( lookupEnv )
import System.Info
    ( os )
import System.IO
    ( Handle, hFlush, hGetLine, hSetNewlineMode, noNewlineTranslation )
import System.IO.Error
    ( IOError )
import Text.Read
    ( readEither )

import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Lazy.Char8 as L8
import qualified Data.Text as T

----------------------------------------------------------------------------
-- Daedalus <-> Wallet child process port discovery protocol

data MsgIn = QueryPort
    deriving (Show, Eq)
data MsgOut = Started | ReplyPort Int | ParseError Text
    deriving (Show, Eq)

instance FromJSON MsgIn where
    parseJSON = withObject "MsgIn" $ \v -> do
        (_ :: [()]) <- v .: "QueryPort"
        pure QueryPort

instance ToJSON MsgIn where
    toJSON QueryPort = object [ "QueryPort" .= Array mempty ]

instance ToJSON MsgOut where
    toJSON Started = object [ "Started" .= Array mempty ]
    toJSON (ReplyPort p) = object [ "ReplyPort" .= p ]
    toJSON (ParseError e) = object [ "ParseError" .= e ]

-- | Start up the Daedalus IPC process. It's called 'daedalusIPC', but this
-- could be any nodejs program that needs to start cardano-wallet. All it does
-- is reply with a port number when asked, using a very nodejs-specific IPC
-- method.
--
-- If the IPC channel was successfully set up, this function won't return until
-- the parent process exits. Otherwise, it will return immediately. Before
-- returning, it will log an message about why it has exited.
daedalusIPC
    :: Tracer IO DaedalusIPCLog
    -- ^ Logging object
    -> Int
    -- ^ Port number to send to Daedalus
    -> IO ()
daedalusIPC tr port = runNodeChannel hello (withLog msg) >>= \case
    Right runServer -> do
        NodeChannelFinished err <- runServer
        traceWith tr $ MsgFinished $ T.pack $ show err
    Left NodeChannelDisabled -> do
        traceWith tr MsgNotEnabled
        threadDelay maxBound
    Left (NodeChannelBadFD err) ->
        traceWith tr $ MsgStartupError err
  where
    -- Introductory message
    hello = do
        traceWith tr MsgSendHello
        pure Started

    -- How to respond to an incoming message, or when there is an incoming
    -- message that couldn't be parsed.
    msg (Right QueryPort) = pure $ Just (ReplyPort port)
    msg (Left e) = pure $ Just (ParseError e)

    withLog action m = traceWith tr (MsgReceive m) >> action m

----------------------------------------------------------------------------
-- Logging

data DaedalusIPCLog
    = MsgStarting
    | MsgNotEnabled
    | MsgStartupError Text
    | MsgSendHello
    | MsgReceive (Either Text MsgIn)
    | MsgFinished Text
    deriving (Generic, Show, Eq, ToJSON)

instance ToText DaedalusIPCLog where
    toText = \case
        MsgStarting -> "Daedalus IPC server starting"
        MsgNotEnabled -> "Daedalus IPC is not enabled."
        MsgStartupError err -> "Problem starting Daedalus IPC: " <> err
        MsgSendHello -> "Sending Started"
        MsgReceive (Right QueryPort) -> "Received QueryPort"
        MsgReceive (Left _) -> "Received unknown message"
        MsgFinished err ->
            "Daedalus IPC finished for this reason: " <> err

instance ToObject DaedalusIPCLog
instance HasPrivacyAnnotation DaedalusIPCLog
instance HasSeverityAnnotation DaedalusIPCLog where
    getSeverityAnnotation = \case
        MsgStarting -> Info
        MsgNotEnabled -> Info
        MsgStartupError _ -> Error
        MsgSendHello -> Debug
        MsgReceive _ -> Debug
        MsgFinished _ -> Notice

----------------------------------------------------------------------------
-- NodeJS child_process IPC protocol
-- https://nodejs.org/api/child_process.html#child_process_child_process_spawn_command_args_options

-- | Possible reasons why the node channel can't be set up.
data NodeChannelError
    = NodeChannelDisabled
      -- ^ This process has not been started as a nodejs @'ipc'@ child_process.
    | NodeChannelBadFD Text
      -- ^ The @NODE_CHANNEL_FD@ environment variable has an incorrect value.
    deriving (Show, Eq)

-- | The only way a node channel finishes on its own is if there is some error
-- reading or writing to its file descriptor.
newtype NodeChannelFinished = NodeChannelFinished IOError

-- | Communicate with a parent process using a NodeJS-specific protocol. This
-- process must have been spawned with one of @stdio@ array entries set to
-- @'ipc'@.
--
-- If the channel could be set up, then it returns a function for communicating
-- with the parent process.
runNodeChannel
    :: (FromJSON msgin, ToJSON msgout)
    => IO msgout
       -- ^ Action to get the "Hello" message sent from child process.
    -> (Either Text msgin -> IO (Maybe msgout))
       -- ^ Handler for messages coming from the parent process. Left values are
       -- for JSON parse errors. The handler can optionally return a reply
       -- message.
    -> IO (Either NodeChannelError (IO NodeChannelFinished))
runNodeChannel hello onMsg = fmap setup <$> lookupNodeChannel
  where
    setup handle = ipcListener handle hello onMsg

-- | Parse the NODE_CHANNEL_FD variable, if it's set, and convert to a
-- 'System.IO.Handle'.
lookupNodeChannel :: IO (Either NodeChannelError Handle)
lookupNodeChannel = (fromMaybe "" <$> lookupEnv "NODE_CHANNEL_FD") >>= \case
    "" -> pure (Left NodeChannelDisabled)
    var -> case readEither var of
        Left err -> pure . Left . NodeChannelBadFD $
           "unable to parse NODE_CHANNEL_FD: " <> T.pack err
        Right fd -> tryJust handleBadFd (fdToHandle fd)
  where
    handleBadFd :: IOException -> Maybe NodeChannelError
    handleBadFd = Just . NodeChannelBadFD . T.pack . show

ipcListener
    :: forall msgin msgout. (FromJSON msgin, ToJSON msgout)
    => Handle
    -> IO msgout
    -> (Either Text msgin -> IO (Maybe msgout))
    -> IO NodeChannelFinished
ipcListener handle hello onMsg = do
    hSetNewlineMode handle noNewlineTranslation
    hello >>= sendMsg
    replyLoop `catch` (pure . NodeChannelFinished)
  where
    replyLoop :: IO a
    replyLoop = forever (recvMsg >>= onMsg >>= maybeSend)

    recvMsg :: IO (Either Text msgin)
    recvMsg = fmap (first T.pack) $ (>>= eitherDecode) <$> readMessage handle

    sendMsg :: msgout -> IO ()
    sendMsg = sendMessage handle . encode

    maybeSend :: Maybe msgout -> IO ()
    maybeSend = maybe (pure ()) sendMsg

readMessage :: Handle -> IO (Either String BL.ByteString)
readMessage =
    if isWindows
    then windowsReadMessage
    else fmap Right . posixReadMessage

isWindows :: Bool
isWindows = os == "mingw32"

windowsReadMessage :: Handle -> IO (Either String BL.ByteString)
windowsReadMessage handle = runExceptT $ do
    _int1 <- readInt32 handle
    _int2 <- readInt32 handle
    size  <- readInt64 handle
    lift $ BL.hGet handle $ fromIntegral size
  where
    readInt64 :: Handle -> ExceptT String IO Word64
    readInt64 hnd = do
        bs <- lift $ BL.hGet hnd 8
        except $ eitherRunGet getWord64le bs

    readInt32 :: Handle -> ExceptT String IO Word32
    readInt32 hnd = do
        bs <- lift $ BL.hGet hnd 4
        except $ eitherRunGet getWord32le bs

posixReadMessage :: Handle -> IO BL.ByteString
posixReadMessage = fmap L8.pack . hGetLine

sendMessage :: Handle -> BL.ByteString -> IO ()
sendMessage handle msg = send handle msg >> hFlush handle
  where
    send = if isWindows then sendMessageWindows else sendMessagePosix

sendMessageWindows :: Handle -> BL.ByteString -> IO ()
sendMessageWindows = sendWindowsMessage' 1 0

sendWindowsMessage' :: Word32 -> Word32 -> Handle -> BL.ByteString -> IO ()
sendWindowsMessage' int1 int2 handle blob =
    L8.hPut handle $ runPut $ mconcat parts
  where
    blob' = blob <> "\n"
    parts =
        [ putWord32le int1
        , putWord32le int2
        , putWord64le $ fromIntegral $ BL.length blob'
        , putLazyByteString blob'
        ]

sendMessagePosix :: Handle -> BL.ByteString -> IO ()
sendMessagePosix = L8.hPutStrLn
