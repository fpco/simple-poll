{-# LANGUAGE Trustworthy #-}
{-# LANGUAGE GeneralizedNewtypeDeriving
           , BangPatterns
  #-}
{-# LANGUAGE ExistentialQuantification, NoImplicitPrelude #-}

-- Note: code largely taken from the ghc code base, see
-- <https://github.com/ghc/ghc/commit/8952cc3e8e36985b06166c23c482174b07ffa66d>
-- for licensing and copyright and
-- <https://github.com/ghc/ghc/blob/8952cc3e8e36985b06166c23c482174b07ffa66d/libraries/base/GHC/Event/EPoll.hsc>
-- for the original code.

-----------------------------------------------------------------------------
-- |
-- A binding to the epoll I/O event notification facility
--
-- epoll is a variant of poll that can be used either as an edge-triggered or
-- a level-triggered interface and scales well to large numbers of watched file
-- descriptors.
--
-- epoll decouples monitor an fd from the process of registering it.
--
-----------------------------------------------------------------------------

module System.Poll.EPoll
    ( EPoll
    , new
    , delete
    , with
    , control
    , wait
    , Event(..)
    , EventType
    , epollIn
    , epollOut
    , epollRdHup
    , epollPri
    , epollErr
    , epollHup
    , epollET
    , epollOneShot
    , Op
    , controlOpAdd
    , controlOpModify
    , controlOpDelete
    ) where

#include <sys/epoll.h>

import Data.Bits ((.|.), (.&.), Bits, FiniteBits)
import Data.Word (Word32)
import Foreign.C.Error (eNOENT, getErrno, throwErrno, throwErrnoIfMinus1, throwErrnoIfMinus1_)
import Foreign.C.Types (CInt(..))
import qualified Foreign.Marshal.Utils
import Foreign.Ptr (Ptr)
import Foreign.Storable (Storable(..))
import GHC.Base
import GHC.Num (Num(..))
import GHC.Real (ceiling, fromIntegral)
import GHC.Show (Show)
import System.Posix.Internals (c_close)
import System.Posix.Internals (setCloseOnExec)
import System.Posix.Types (Fd(..))
import Control.Exception (bracket)
import qualified Data.Vector.Storable.Mutable as VM
import qualified Data.Vector.Storable as V
import Foreign.C.Error (eINTR, getErrno, throwErrno)
import Text.Show (show)
import Foreign.C.Types (CInt)
import Prelude (putStrLn)
import Data.Maybe (fromMaybe)

data EPoll = EPoll {
      epollFd     :: {-# UNPACK #-} !EPollFd
    , epollEvents :: {-# UNPACK #-} !(VM.IOVector Event)
    }

-- | Create a new epoll backend.
{-# INLINE new #-}
new :: CInt -> IO EPoll
new n = do
  epfd <- epollCreate
  evts <- VM.new (fromIntegral n)
  return (EPoll epfd evts)

{-# INLINE delete #-}
delete :: EPoll -> IO ()
delete be = do
  _ <- c_close . fromEPollFd . epollFd $ be
  return ()

{-# INLINE with #-}
with :: CInt -> (EPoll -> IO a) -> IO a
with n cont = bracket (new n) delete cont

-- When Op = controlOpDel, the Event parameter is ignored.
{-# INLINE control #-}
control :: EPoll -> Op -> Fd -> EventType -> IO ()
control ep op fd event =
  Foreign.Marshal.Utils.with (Event event fd) (epollControl (epollFd ep) op fd)

{-# INLINE wait #-}
wait ::
     EPoll
  -> Maybe CInt
  -- ^ timeout in milliseconds. If 'Nothing', 'wait' will block indefinitely.
  -> Bool
  -- ^ Whether the call to epoll_wait should be unsafe. If unsafe, the
  -- Haskell runtime will be able to do nothing else but wait for epoll_wait
  -- to finish, so use with care.
  -> IO (V.Vector Event)
wait ep mtimeout unsafe = do
  let events = epollEvents ep
  let fd = epollFd ep
  let cap = fromIntegral (VM.length events)

  -- Will return zero if the system call was interrupted, in which case
  -- we just return (and try again later.)
  let timeout = fromMaybe (-1) mtimeout -- Wait indefinitely if no timeout is provided
  n <- VM.unsafeWith events $ \es -> if unsafe
    then epollWaitUnsafe fd es cap timeout
    else epollWait fd es cap timeout

  -- TODO remove this check
  when (n < 0 || n > cap) $
    fail $ "EPoll impossible: got less than 0 or greater than cap " ++ show cap

  -- when (n == 0) $
  --   putStrLn "GOT n == 0"
  V.freeze (VM.unsafeTake (fromIntegral n) events)

newtype EPollFd = EPollFd {
      fromEPollFd :: CInt
    } deriving (Eq, Show)

data Event = Event {
      eventTypes :: EventType
    , eventFd    :: Fd
    } deriving (Show)

-- | @since 4.3.1.0
instance Storable Event where
    sizeOf    _ = #size struct epoll_event
    alignment _ = alignment (undefined :: CInt)

    peek ptr = do
        ets <- #{peek struct epoll_event, events} ptr
        ed  <- #{peek struct epoll_event, data.fd}   ptr
        let !ev = Event (EventType ets) ed
        return ev

    poke ptr e = do
        #{poke struct epoll_event, events} ptr (unEventType $ eventTypes e)
        #{poke struct epoll_event, data.fd}   ptr (eventFd e)

newtype Op = Op CInt
  deriving (Eq, Show)

#{enum Op, Op
 , controlOpAdd    = EPOLL_CTL_ADD
 , controlOpModify = EPOLL_CTL_MOD
 , controlOpDelete = EPOLL_CTL_DEL
 }

newtype EventType = EventType {
      unEventType :: Word32
    } deriving (Show, Eq, Bits, FiniteBits)

#{enum EventType, EventType
 , epollIn  = EPOLLIN
 , epollOut = EPOLLOUT
 , epollRdHup = EPOLLRDHUP
 , epollPri = EPOLLPRI
 , epollErr = EPOLLERR
 , epollHup = EPOLLHUP
 , epollET = EPOLLET
 , epollOneShot = EPOLLONESHOT
 }

-- | Create a new epoll context, returning a file descriptor associated with the context.
-- The fd may be used for subsequent calls to this epoll context.
--
-- The size parameter to epoll_create is a hint about the expected number of handles.
--
-- The file descriptor returned from epoll_create() should be destroyed via
-- a call to close() after polling is finished
--
epollCreate :: IO EPollFd
epollCreate = do
  fd <- throwErrnoIfMinus1 "epollCreate" $
        c_epoll_create 256 -- argument is ignored
  setCloseOnExec fd
  let !epollFd' = EPollFd fd
  return epollFd'

epollControl :: EPollFd -> Op -> Fd -> Ptr Event -> IO ()
epollControl epfd op fd event =
    throwErrnoIfMinus1_ "epollControl" $ epollControl_ epfd op fd event

epollControl_ :: EPollFd -> Op -> Fd -> Ptr Event -> IO CInt
epollControl_ (EPollFd epfd) (Op op) (Fd fd) event =
    c_epoll_ctl epfd op fd event

epollWait :: EPollFd -> Ptr Event -> CInt -> CInt -> IO CInt
epollWait (EPollFd epfd) events numEvents timeout =
    throwErrnoIfMinus1NoRetry "epollWait" $
    c_epoll_wait epfd events numEvents timeout

epollWaitUnsafe :: EPollFd -> Ptr Event -> CInt -> CInt -> IO CInt
epollWaitUnsafe (EPollFd epfd) events numEvents timeout =
  throwErrnoIfMinus1NoRetry "epollWaitUnsafe" $
  c_epoll_wait_unsafe epfd events numEvents timeout

foreign import ccall unsafe "sys/epoll.h epoll_create"
    c_epoll_create :: CInt -> IO CInt

foreign import ccall unsafe "sys/epoll.h epoll_ctl"
    c_epoll_ctl :: CInt -> CInt -> CInt -> Ptr Event -> IO CInt

foreign import ccall safe "sys/epoll.h epoll_wait"
    c_epoll_wait :: CInt -> Ptr Event -> CInt -> CInt -> IO CInt

foreign import ccall unsafe "sys/epoll.h epoll_wait"
    c_epoll_wait_unsafe :: CInt -> Ptr Event -> CInt -> CInt -> IO CInt


-- | Throw an 'IOError' corresponding to the current value of
-- 'getErrno' if the result value of the 'IO' action is -1 and
-- 'getErrno' is not 'eINTR'.  If the result value is -1 and
-- 'getErrno' returns 'eINTR' 0 is returned.  Otherwise the result
-- value is returned.
throwErrnoIfMinus1NoRetry :: (Eq a, Num a) => String -> IO a -> IO a
throwErrnoIfMinus1NoRetry loc f = do
    res <- f
    if res == -1
        then do
            err <- getErrno
            if err == eINTR then putStrLn "GOT EINTR" >> return 0 else throwErrno loc
        else return res
