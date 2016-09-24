{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Rash.Process where

import qualified GHC.IO.Handle as Handle
import           Control.Monad.IO.Class (liftIO)
import           Control.Monad (void)
import qualified System.Process as Proc
import qualified Data.Map.Strict as Map
import qualified Control.Concurrent.Async as Async
import           Control.Exception (throw)
import qualified Control.Monad.Trans.State as State


import Rash.AST
import Rash.Runtime as Runtime
import Rash.Debug

evalPipe :: [(String, [Value])] -> Handle.Handle -> EvalExprFn -> WithState Value
evalPipe commands stdin evalProgram = do
  -- TODO: when you call a pipe, what do you do with the "output"? Obviously,
  -- you stream it to the parent. And occasionally the parent will be stdout. So
  -- clearly, we need to pass - implicitly - the handle from the calling
  -- function.
  -- However, that breaks our metaphor of "returning" a packet with the streams in it...
  -- TODO: we need to handle stderr too.
  -- TODO support exit codes

  stdout <- getStdout
  stderr <- getStderr

  do
    pipes :: [(Handle.Handle, Handle.Handle)] <- liftIO $ mapM (const Proc.createPipe) commands
    let pipes1 :: [(Handle.Handle, Handle.Handle)] = tail pipes
    let pipes2 :: [Handle.Handle] = foldl (\c (a,b) -> c ++ [a, b]) [] pipes1
    let pipes3 :: [Handle.Handle] = [stdin] ++ pipes2 ++ [stdout]
    let joiner = (\case
                   (a:b:cs) -> [Handles a b stderr] ++ (joiner cs)
                   [_] -> error "shouldn't happen"
                   [] -> [])

    let pipes4 :: [Handles] = joiner pipes3

    let entirity = zip pipes4 commands

    procs <- mapM buildSegment entirity

    _ <- liftIO $ mapM waitForProcess procs
    return VNull


  where
    buildSegment :: (Handles, (String, [Value])) -> WithState (Process)
    buildSegment (handles, (cmd, args)) = do
      ft <- getFuncTable
      let func = Map.lookup cmd ft
      procHandle <- case func of
        Just f -> createFuncThread f args handles evalProgram
        Nothing -> liftIO $ createBackgroundProc cmd args handles
      return procHandle


data Process = FuncProc (Async.Async ()) | ProcProc Proc.ProcessHandle

waitForProcess :: Process -> IO ()
waitForProcess (FuncProc asyncid) = do
  e <- Async.waitCatch asyncid
  either throw return e
waitForProcess (ProcProc handle) = void $ Proc.waitForProcess handle

value2ProcString :: Value -> String
value2ProcString (VString s) = s
value2ProcString (VInt i) = show i
value2ProcString x = todo "valueToProcString" x



createBackgroundProc :: String -> [Value] -> Handles -> IO Process
createBackgroundProc cmd args (Handles stdin stdout stderr) = do
  let p = (Proc.proc cmd (map value2ProcString args)) {
      Proc.std_in = Proc.UseHandle stdin
    , Proc.std_out = Proc.UseHandle stdout
    , Proc.std_err = Proc.UseHandle stderr
    , Proc.close_fds = True }
  (_, _, _, proc) <- liftIO $ Proc.createProcess_ cmd p
  return $ ProcProc proc


createFuncThread :: Function -> [Value] -> Handles -> EvalExprFn -> WithState Process
createFuncThread func args handles evalExpr = do
  state <- getState

  asyncid <- do liftIO $ Async.async $ do
                  _ <- runFunction func args handles state evalExpr
                  return ()
  return $ FuncProc asyncid

runFunction :: Function -> [Value] -> Handles -> IState -> EvalExprFn -> IO Value
runFunction (UserDefined (FuncDef _ params body))
            args handles state evalExpr = do
  -- new stack frame, with args TODO: copy the "globals"
  let st = foldr (\((FunctionParameter param), arg)
                   table
                   -> Map.insert param arg table)
                   Map.empty
                   (zip params args)
  let newState = state { frame_ = Frame st handles }

  State.evalStateT (evalExpr body) newState

runFunction (Builtin fn) args handles state _ = do
  let newState = state { frame_ = Frame Map.empty handles }
  State.evalStateT (fn args) $ newState