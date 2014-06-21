{-# LANGUAGE OverloadedStrings #-}

import Control.Monad.Reader
import Control.Monad.Trans.State.Strict
import Data.List
import Data.Maybe
import Network
import Prelude hiding (log)
import System.IO
import System.Time

import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as C8

import qualified Pipes.Network.TCP as PNT
import qualified Pipes.Attoparsec as PA
import qualified Pipes.Prelude as PP
import Pipes

-- NSQ parser
import qualified Network.NSQ as NSQ
import Control.Applicative

import Debug.Trace

-- Per server config for the test
data ServerConfig = ServerConfig
    { server :: String
    , port :: PortNumber
    , logfile :: String
    }

-- Ephemeral State:
data ServerState = ServerState
    { config :: ServerConfig
    , logStream :: Handle
    }


--
-- State:
--  * Per nsqd (connection) state (rdy, load balance, etc)
--  * Per topic state (channel related info and which nsqd connection)
--  * Global? state (do we have any atm? maybe configuration?)
--


--
-- High level arch:
--  * One queue per topic/channel
--  * This queue can be feed by multiple nsqd (load balanced/nsqlookup for ex)
--  * Probably will have one set of state/config per nsqd connection and per queue/topic/channel
--  * Can probably later on provide helpers for consuming the queue
--
-- Detail:
--  * Support connecting to a particular nsqd and doing the needful to
--  establish identification and so forth
--  * Auto-handle heartbeat and all related stuff
--  * A higher layer will handle the message reading/balancing between multiplex nsqd connection for a particular topic/channel
--
-- Note:
--  * One sub (topic/channel) per nsqd connection max, any more will get an E_INVALID
--  * Seems to be able to publish to any topic/channel without limitation
--


testConfig :: ServerConfig
--testConfig = ServerConfig "glcwalker.ohl" 4150 "./test.log"
--testConfig = ServerConfig "10.0.0.171" 4150 "./test.log"
testConfig = ServerConfig "127.0.0.1" 4150 "./test.log"

--
-- Establish a session with this server
--
establish :: ServerConfig -> IO ()
establish sc = PNT.withSocketsDo $
    -- Establish the logfile
    withFile (logfile sc) AppendMode (\l ->

        -- Establish stocket
        PNT.connect (server sc) (show $ port sc) (\(sock, _) -> do

            -- Set log to be unbuffered for testing
            hSetBuffering l NoBuffering

            handleNSQ (PNT.fromSocket sock 8192 >-> log l) (log l >-> PNT.toSocket sock) (ServerState sc l)

            return ()
        )
    )

--
-- The NSQ handler and protocol
--
handleNSQ :: (Monad m, MonadIO m) => Producer BS.ByteString m () -> Consumer BS.ByteString m () -> ServerState -> m ()
handleNSQ recv send ss = do
    -- Initial connection
    runEffect $ handshake ss >-> showCommand >-> send

    -- Regular nsq streaming
    runEffect $ (nsqParserErrorLogging (logStream ss) recv) >-> command >-> showCommand >-> send

    return ()

--
-- Parses incoming nsq messages and emits any errors to a log and keep going
--
nsqParserErrorLogging :: MonadIO m => Handle -> Producer BS.ByteString m () -> Producer NSQ.Message m ()
nsqParserErrorLogging l producer = do
    (result, rest) <- lift $ runStateT (PA.parse NSQ.message) producer

    case result of
        Nothing -> liftIO $ BS.hPutStr l "Pipe is exhausted for nsq parser\n"
        Just y  -> do
            case y of
                Right x -> traceShow x $ yield x
                Left x  -> liftIO $ BS.hPutStr l $ BS.concat
                            [ "===========\n"
                            , "\n"
                            , C8.pack $ show x -- TODO: Ascii packing
                            , "\n"
                            , "===========\n"
                            ]
            nsqParserErrorLogging l rest

--
-- Format outbound NSQ Commands
--
showCommand :: Monad m => Pipe NSQ.Command BS.ByteString m ()
showCommand = PP.map encode
    where
        encode = NSQ.encode

--
-- Handshake for the initial connection to the network
--
handshake :: Monad m => ServerState -> Producer NSQ.Command m ()
handshake ss = do

    yield $ NSQ.Protocol
    yield $ NSQ.Identify $ (NSQ.defaultIdentify "pharaun-ASDF" "netheril.elder.lan."){NSQ.heartbeatInterval = Just $ NSQ.Custom 1000}

    -- sub to a channel
    yield $ NSQ.Sub "glc-gamestate" "netheril.elder.lan." False

    -- Publish
    yield $ NSQ.Pub "glc-gamestate" "{}"

    yield $ NSQ.MPub "glc-gamestate" ["{}", "{}", "{}"]

    -- Open floodgate for 1 msg at a time
    yield $ NSQ.Rdy 1

    return ()

--
-- Log anything that passes through this stream to a logfile
--
log :: MonadIO m => Handle -> Pipe BS.ByteString BS.ByteString m r
log h = forever $ do
    x <- await
    liftIO $ BS.hPutStr h $ BS.concat [x, "\n"]
    yield x

--
-- Do something with the inbound message
--
command :: (Monad m, MonadIO m) => Pipe NSQ.Message NSQ.Command m ()
command = forever $ do
    msg <- await

    case msg of
        NSQ.Heartbeat         -> yield $ NSQ.NOP
        NSQ.Message _ _ mId c -> do
            liftIO $ BS.hPutStr stdout c
            yield $ NSQ.Fin mId
            --yield $ NSQ.Rdy 1

        otherwise             -> return ()


--             | Fin MsgId
--             | Req MsgId Word64 -- msgid, timeout
--             | Touch MsgId
--             | Cls