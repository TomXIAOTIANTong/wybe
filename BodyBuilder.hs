--  File     : BodyBuilder.hs
--  RCS      : $Id$
--  Author   : Peter Schachte
--  Origin   : Fri 22 May 2015 10:59:56 AEST
--  Purpose  : A monad to build up a procedure Body, with copy propagation
--  Copyright: (c) 2015 Peter Schachte.  All rights reserved.
--

module BodyBuilder (
  BodyBuilder, buildBody, instr, buildFork
  ) where

import AST
import Snippets
import Options (LogSelection(BodyBuilder))
import Data.Map as Map
import Data.List as List
import Data.Bits
import Control.Monad
import Control.Monad.Trans (lift)
import Control.Monad.Trans.State


----------------------------------------------------------------
--                       The BodyBuilder Monad
--
-- This monad keeps track of variable renaming needed to keep inlining
-- hygenic.  To do this, we rename all the input parameters of the proc to 
-- be inlined, and when expanding the body, we rename any variables when 
-- first assigned.  The exception to this is the proc's output parameters.  
-- These are kept as a set.  We also maintain a counter for temporary 
-- variable names.
----------------------------------------------------------------

type BodyBuilder = StateT BodyState Compiler

data BodyState
    = Unforked {
      currBuild :: [Placed Prim],   -- ^The body we're building, reversed
      currSubst :: Substitution,    -- ^variable substitutions to propagate
      outSubst  :: VarSubstitution, -- ^Substitutions for variable assignments
      subExprs  :: ComputedCalls    -- ^Previously computed calls to reuse
      }
    | Forked {
      initBuild   :: [Placed Prim],   -- ^Statements before the fork, reversed
      stForkVar   :: PrimVarName,     -- ^Variable that selects branch to take
      stForkVarTy :: TypeSpec,        -- ^Type of stForkVar
      stForkBods  :: [BodyState]      -- ^BodyStates of all the branches
      }
    deriving (Eq,Show)

type Substitution = Map PrimVarName PrimArg
type VarSubstitution = Map PrimVarName PrimVarName

-- To handle common subexpression elimination, we keep a map from previous
-- calls with their outputs removed to the outputs.  This type encapsulates
-- that.  In the Prim keys, all PrimArgs are inputs.
type ComputedCalls = Map Prim [PrimArg]

-- instance Show BodyBuildState where
--   show (Unforked revPrims) =
--       showBlock 4 $ ProcBody (reverse revPrims) NoFork
--   show (Forked body) = show body

currBody :: BodyState -> ProcBody
currBody (Unforked prims _ _ _)     = ProcBody (reverse prims) NoFork
currBody (Forked prims var ty bods) = ProcBody (reverse prims) $
    PrimFork var ty False $ List.map currBody bods

initState :: VarSubstitution -> BodyState
initState oSubst = Unforked [] Map.empty oSubst Map.empty


----------------------------------------------------------------
--                      BodyBuilder Primitive Operations
----------------------------------------------------------------

-- |Run a BodyBuilder monad and extract the final proc body
buildBody :: VarSubstitution -> BodyBuilder a -> Compiler (a,ProcBody)
buildBody oSubst builder = do
    logMsg BodyBuilder "<<<< Beginning to build a proc body"
    (a,st) <- buildPrims (initState oSubst) builder
    logMsg BodyBuilder ">>>> Finished  building a proc body"
    return (a,currBody st)


buildFork :: PrimVarName -> TypeSpec -> Bool -> [BodyBuilder ()] 
             -> BodyBuilder ()
buildFork var ty final branchBuilders = do
    st <- get
    case st of
      Forked bld var ty bods -> do
        -- This shouldn't usually happen, but it can happen when a test
        -- proc is inlined.  Handle by building the fork at the end of
        -- each of the branches.
        bods' <- mapM (\st -> lift $ execStateT
                              (buildFork var ty final branchBuilders) st) bods
        put $ Forked bld var ty bods'
      Unforked _ _ _ _ -> do
        logBuild $ "<<<< beginning to build a new fork on " ++ show var
            ++ " (final=" ++ show final ++ ")"
        arg' <- expandArg $ ArgVar var ty FlowIn Ordinary False
        case arg' of
          ArgInt n _ -> -- result known at compile-time:  only compile winner
            case drop (fromIntegral n) branchBuilders of
              -- XXX should be an error message rather than an abort
              [] -> shouldnt "branch constant greater than number of cases"
              (winner:_) -> do
                logBuild $ "**** condition result is " ++ show n
                winner
          ArgVar var' ty _ _ _ -> do -- statically unknown result
            st <- get
            case st of
              Forked _ _ _ _ -> 
                nyi "Fork after a fork"
              Unforked build _ _ _ -> do
                let st' = st { currBuild = [] }
                branches <- mapM (buildBranch st') branchBuilders
                case branches of
                  [] -> return ()
                  [br] -> put $ concatBodies st br
                  (br:brs) | all (==br) brs -> 
                    -- all branches are equal:  don't create a new fork
                    put $ concatBodies st br
                  brs ->
                    put $ Forked build var' ty brs
          _ -> shouldnt "Switch on non-integer value"
        logBuild $ ">>>> Finished building a fork"


buildBranch :: BodyState -> BodyBuilder () -> BodyBuilder BodyState
buildBranch st builder = do
    logBuild "<<<< <<<< Beginning to build a branch"
    branch <- lift $ fmap snd $ buildPrims st builder
    logBuild ">>>> >>>> Finished  building a branch"
    return branch


buildPrims :: BodyState -> BodyBuilder a -> Compiler (a,BodyState)
buildPrims st builder = runStateT builder st


-- |Add an instruction to the current body, after applying the current
--  substitution. If it's a move instruction, add it to the current
--  substitution, and only add it if it assigns a protected variable.
instr :: Prim -> OptPos -> BodyBuilder ()
instr PrimNop _ = do
    -- Filter out NOPs
    return ()
instr prim pos = do
    st <- get
    case st of
      Unforked _ _ _ _ -> do
        logBuild $ "Generating instr " ++ show prim
        prim' <- argExpandedPrim prim
        instr' prim' pos
      Forked bld var ty bods -> do
        bods' <- mapM (flip buildBranch (instr prim pos)) bods
        put $ Forked bld var ty bods'


instr' :: Prim -> OptPos -> BodyBuilder ()
instr' prim@(PrimForeign "llvm" "move" []
           [val, argvar@(ArgVar var _ flow _ _)]) pos
  = do
    logBuild $ "  Expanding move(" ++ show val ++ ", " ++ show argvar ++ ")"
    unless (flow == FlowOut && argFlowDirection val == FlowIn) $ 
      shouldnt "move instruction with wrong flow"
    outVar <- gets (Map.findWithDefault var var . outSubst)
    addSubst outVar val
    rawInstr prim pos
-- XXX this is a bit of a hack to work around not threading a heap
--     through the code, which causes the compiler to try to reuse
--     the results of calls to alloc.  Since the mutate primitives
--     already have an output value, that should stop us from trying
--     to reuse modified structures or the results of calls to
--     access after a structure is modified, so alloc should be
--     the only problem that needs fixing.  We don't want to fix this
--     by threading a heap through, because it's fine to reorder calls
--     to alloc.
instr' prim@(PrimForeign "lpvm" "alloc" [] args) pos
  = do
    logBuild $ "  Leaving alloc alone"
    rawInstr prim pos
instr' prim pos = do
    let (prim',newOuts) = splitPrimOutputs prim
    logBuild $ "Looking for computed instr " ++ show prim' ++ " ..."
    match <- gets (Map.lookup prim' . subExprs)
    case match of
        Nothing -> do
            -- record prim executed (and other modes), and generate instr
            logBuild $ "not found"
            addAllModes prim
            rawInstr prim pos
        Just oldOuts -> do
            -- common subexpr: just need to record substitutions
            logBuild $ "found it; substituting "
                       ++ show oldOuts ++ " for " ++ show newOuts
            mapM_ (\(newOut,oldOut) -> addSubst (outArgVar newOut)
                                       (outVarIn oldOut))
                  $ zip newOuts oldOuts


outVarIn :: PrimArg -> PrimArg
outVarIn (ArgVar name ty FlowOut ftype lst) =
    ArgVar name ty FlowIn Ordinary False
outVarIn arg =
    shouldnt $ "outVarIn not actually out: " ++ show arg


argExpandedPrim :: Prim -> BodyBuilder Prim
argExpandedPrim (PrimCall pspec args) = do
    args' <- mapM expandArg args
    return $ PrimCall pspec args'
argExpandedPrim (PrimForeign lang nm flags args) = do
    args' <- mapM expandArg args
    return $ simplifyForeign lang nm flags args'
argExpandedPrim PrimNop =
    shouldnt "argExpandedPrim: Nops should be filtered out by now"


splitPrimOutputs :: Prim -> (Prim, [PrimArg])
splitPrimOutputs (PrimCall pspec args) =
    let (inArgs,outArgs) = splitArgsByMode args
    in (PrimCall pspec inArgs, outArgs)
splitPrimOutputs (PrimForeign lang nm flags args) = 
    let (inArgs,outArgs) = splitArgsByMode args
    in (PrimForeign lang nm flags inArgs, outArgs)
splitPrimOutputs PrimNop =
    shouldnt "splitPrimOutputs: Nops should be filtered out by now"


-- |Add a binding for a variable. If that variable is an output for the
--  proc being defined, also add an explicit assignment to that variable.
addSubst :: PrimVarName -> PrimArg -> BodyBuilder ()
addSubst var val = do
    logBuild $ "      adding subst " ++ show var ++ " -> " ++ show val
    modify (\s -> s { currSubst = Map.insert var val $ currSubst s })
    subst <- gets currSubst
    logBuild $ "      new subst = " ++ show subst


-- |Add all instructions equivalent to the input prim to the lookup table,
--  so if we later see an equivalent instruction we don't repeat it but
--  reuse the already-computed outputs.  This implements common subexpression
--  elimination.  It can also handle optimisations like recognizing the
--  reconstruction of a deconstructed value.
--  XXX Doesn't yet handle multiple modes.
--  XXX Doesn't handle arithmetic identities like commutative addition,
--      if that's a good way to handle them.
addAllModes :: Prim -> BodyBuilder ()
addAllModes (PrimCall pspec args) = do
    let (inArgs,outArgs) = splitArgsByMode args
    let fakeInstr = PrimCall pspec inArgs
    logBuild $ "Recording computed instr " ++ show fakeInstr
    modify (\s -> s {subExprs = Map.insert fakeInstr outArgs $ subExprs s})
addAllModes (PrimForeign lang nm flags args)  = do
    let (inArgs,outArgs) = splitArgsByMode args
    let fakeInstr = PrimForeign lang nm flags inArgs
    logBuild $ "Recording computed instr " ++ show fakeInstr
    modify (\s -> s {subExprs = Map.insert fakeInstr outArgs $ subExprs s})
addAllModes PrimNop =
    shouldnt "splitPrimOutputs: Nops should be filtered out by now"


-- |Unconditionally add an instr to the current body
rawInstr :: Prim -> OptPos -> BodyBuilder ()
rawInstr prim pos = do
    logBuild $ "---- adding instruction " ++ show prim
    validateInstr prim
    modify $ addInstrToState (maybePlace prim pos)
    logBuild $ "---- added " ++ show prim


splitArgsByMode :: [PrimArg] -> ([PrimArg], [PrimArg])
splitArgsByMode =
    List.foldr (\a (ins,outs) -> if argFlowDirection a == FlowIn
                                 then (a:ins,outs)
                                 else (ins,a:outs))
    ([],[])


validateInstr :: Prim -> BodyBuilder ()
validateInstr instr@(PrimCall _ args) =        mapM_ (validateArg instr) args
validateInstr instr@(PrimForeign _ _ _ args) = mapM_ (validateArg instr) args
validateInstr PrimNop = return ()

validateArg :: Prim -> PrimArg -> BodyBuilder ()
validateArg instr (ArgVar _ ty _ _ _) = validateType ty instr
validateArg instr (ArgInt    _ ty)    = validateType ty instr
validateArg instr (ArgFloat  _ ty)    = validateType ty instr
validateArg instr (ArgString _ ty)    = validateType ty instr
validateArg instr (ArgChar   _ ty)    = validateType ty instr

validateType :: TypeSpec -> Prim -> BodyBuilder ()
validateType InvalidType instr =
    shouldnt $ "InvalidType in argument of " ++ show instr
-- XXX AnyType is now a valid type treated as a word type
-- validateType AnyType instr =
--     shouldnt $ "AnyType in argument of " ++ show instr
validateType _ instr = return ()


concatBodies :: BodyState -> BodyState -> BodyState
concatBodies (Unforked revBody1 _ _ _) (Unforked revBody2 subs osubs comp)
    = Unforked (revBody2 ++ revBody1) subs osubs comp -- they're reversed
concatBodies (Unforked revBody1 _ _ _) (Forked revBody2 var ty bods)
    = Forked (revBody2 ++ revBody1) var ty bods -- they're reversed
concatBodies _ _ = shouldnt "Fork after fork should have been caught earlier"

addInstrToState :: Placed Prim -> BodyState -> BodyState
addInstrToState ins st@(Unforked _ _ _ _)
    = st { currBuild = ins:currBuild st}
addInstrToState ins st@(Forked _ _ _ _)
    = st { stForkBods = List.map (addInstrToState ins) $ stForkBods st }


-- |Return the current ultimate value of the input argument.
expandArg :: PrimArg -> BodyBuilder PrimArg
expandArg arg@(ArgVar var _ FlowIn _ _) = do
    var' <- gets (Map.lookup var . currSubst)
    maybe (return arg) expandArg var'
expandArg (ArgVar var typ FlowOut ftype lst) = do
    var' <- gets (Map.findWithDefault var var . outSubst)
    return $ ArgVar var' typ FlowOut ftype lst
expandArg arg = return arg



----------------------------------------------------------------
--                          Extracting the Actual Body
----------------------------------------------------------------

----------------------------------------------------------------
--                              Constant Folding
----------------------------------------------------------------

-- |Transform primitives with all inputs known into a move instruction by
--  performing the operation at compile-time.
simplifyForeign ::  String -> ProcName -> [Ident] -> [PrimArg] -> Prim
simplifyForeign "llvm" op flags args = simplifyOp op flags args
simplifyForeign lang op flags args = PrimForeign lang op flags args


-- |If the specified argument is an input, then it is a constant
constIfInput :: PrimArg -> Bool
constIfInput (ArgVar _ _ FlowIn _ _) = False
constIfInput _ = True


-- | Simplify llvm instructions where possible.  This handles constant
--   folding and simple (single-operation) algebraic simplifications
--   (left and right identities and annihilators).
simplifyOp :: ProcName -> [Ident] -> [PrimArg] -> Prim
-- Integer ops
simplifyOp "add" _ [ArgInt n1 ty, ArgInt n2 _, output] =
  primMove (ArgInt (n1+n2) ty) output
simplifyOp "add" _ [ArgInt 0 ty, arg, output] =
  primMove arg output
simplifyOp "add" _ [arg, ArgInt 0 ty, output] =
  primMove arg output
simplifyOp "sub" _ [ArgInt n1 ty, ArgInt n2 _, output] =
  primMove (ArgInt (n1-n2) ty) output
simplifyOp "sub" _ [arg, ArgInt 0 _, output] =
  primMove arg output
simplifyOp "mul" _ [ArgInt n1 ty, ArgInt n2 _, output] =
  primMove (ArgInt (n1*n2) ty) output
simplifyOp "mul" _ [ArgInt 1 ty, arg, output] =
  primMove arg output
simplifyOp "mul" _ [arg, ArgInt 1 ty, output] =
  primMove arg output
simplifyOp "mul" _ [ArgInt 0 ty, _, output] =
  primMove (ArgInt 0 ty) output
simplifyOp "mul" _ [_, ArgInt 0 ty, output] =
  primMove (ArgInt 0 ty) output
simplifyOp "div" _ [ArgInt n1 ty, ArgInt n2 _, output] =
  primMove (ArgInt (n1 `div` n2) ty) output
simplifyOp "div" _ [arg, ArgInt 1 _, output] =
  primMove arg output
-- Bitstring ops
simplifyOp "and" _ [ArgInt n1 ty, ArgInt n2 _, output] =
  primMove (ArgInt (fromIntegral n1 .&. fromIntegral n2) ty) output
simplifyOp "and" _ [ArgInt 0 ty, _, output] =
  primMove (ArgInt 0 ty) output
simplifyOp "and" _ [_, ArgInt 0 ty, output] =
  primMove (ArgInt 0 ty) output
simplifyOp "and" _ [ArgInt (-1) _, arg, output] =
  primMove arg output
simplifyOp "and" _ [arg, ArgInt (-1) _, output] =
  primMove arg output
simplifyOp "or" _ [ArgInt n1 ty, ArgInt n2 _, output] =
  primMove (ArgInt (fromIntegral n1 .|. fromIntegral n2) ty) output
simplifyOp "or" _ [ArgInt (-1) ty, _, output] =
  primMove (ArgInt (-1) ty) output
simplifyOp "or" _ [_, ArgInt (-1) ty, output] =
  primMove (ArgInt (-1) ty) output
simplifyOp "or" _ [ArgInt 0 _, arg, output] =
  primMove arg output
simplifyOp "or" _ [arg, ArgInt 0 _, output] =
  primMove arg output
simplifyOp "xor" _ [ArgInt n1 ty, ArgInt n2 _, output] =
  primMove (ArgInt (fromIntegral n1 `xor` fromIntegral n2) ty) output
simplifyOp "xor" _ [ArgInt 0 _, arg, output] =
  primMove arg output
simplifyOp "xor" _ [arg, ArgInt 0 _, output] =
  primMove arg output
-- XXX should probably put shift ops here, too
-- Integer comparisons
simplifyOp "icmp" ["eq"] [ArgInt n1 _, ArgInt n2 _, output] =
  primMove (boolConstant $ n1==n2) output
simplifyOp "icmp" ["ne"] [ArgInt n1 _, ArgInt n2 _, output] =
  primMove (boolConstant $ n1/=n2) output
simplifyOp "icmp" ["slt"] [ArgInt n1 _, ArgInt n2 _, output] =
  primMove (boolConstant $ n1<n2) output
simplifyOp "icmp" ["sle"] [ArgInt n1 _, ArgInt n2 _, output] =
  primMove (boolConstant $ n1<=n2) output
simplifyOp "icmp" ["sgt"] [ArgInt n1 _, ArgInt n2 _, output] =
  primMove (boolConstant $ n1>n2) output
simplifyOp "icmp" ["sge"] [ArgInt n1 _, ArgInt n2 _, output] =
  primMove (boolConstant $ n1>=n2) output
simplifyOp "icmp" ["ult"] [ArgInt n1 _, ArgInt n2 _, output] =
  let n1' = fromIntegral n1 :: Word
      n2' = fromIntegral n2 :: Word
  in primMove (boolConstant $ n1'<n2') output
simplifyOp "icmp" ["ult"] [_, ArgInt 0 _, output] = -- nothing is < 0
  primMove (ArgInt 0 boolType) output
simplifyOp "icmp" ["ule"] [ArgInt n1 _, ArgInt n2 _, output] =
  let n1' = fromIntegral n1 :: Word
      n2' = fromIntegral n2 :: Word
  in primMove (boolConstant $ n1'<=n2') output
simplifyOp "icmp" ["ule"] [ArgInt 0 _, _, output] = -- 0 is <= everything
  primMove (ArgInt 1 boolType) output
simplifyOp "icmp" ["ugt"] [ArgInt n1 _, ArgInt n2 _, output] =
  let n1' = fromIntegral n1 :: Word
      n2' = fromIntegral n2 :: Word
  in primMove (boolConstant $ n1'>n2') output
simplifyOp "icmp" ["ugt"] [ArgInt 0 _, _, output] = -- 0 is > nothing
  primMove (ArgInt 0 boolType) output
simplifyOp "icmp" ["uge"] [ArgInt n1 _, ArgInt n2 _, output] =
  let n1' = fromIntegral n1 :: Word
      n2' = fromIntegral n2 :: Word
  in primMove (boolConstant $ n1'>=n2') output
simplifyOp "icmp" ["uge"] [_, ArgInt 0 _, output] = -- everything is >= 0
  primMove (ArgInt 1 boolType) output
-- Float ops
simplifyOp "fadd" _ [ArgFloat n1 ty, ArgFloat n2 _, output] =
  primMove (ArgFloat (n1+n2) ty) output
simplifyOp "fadd" _ [ArgFloat 0 ty, arg, output] =
  primMove arg output
simplifyOp "fadd" _ [arg, ArgFloat 0 ty, output] =
  primMove arg output
simplifyOp "fsub" _ [ArgFloat n1 ty, ArgFloat n2 _, output] =
  primMove (ArgFloat (n1-n2) ty) output
simplifyOp "fsub" _ [arg, ArgFloat 0 _, output] =
  primMove arg output
simplifyOp "fmul" _ [ArgFloat n1 ty, ArgFloat n2 _, output] =
  primMove (ArgFloat (n1*n2) ty) output
simplifyOp "fmul" _ [arg, ArgFloat 1 _, output] =
  primMove arg output
simplifyOp "fmul" _ [ArgFloat 1 _, arg, output] =
  primMove arg output
-- We don't handle float * 0.0 because of the semantics of IEEE floating mult.
simplifyOp "fdiv" _ [ArgFloat n1 ty, ArgFloat n2 _, output] =
  primMove (ArgFloat (n1/n2) ty) output
simplifyOp "fdiv" _ [arg, ArgFloat 1 _, output] =
  primMove arg output
-- Float comparisons
simplifyOp "fcmp" ["eq"] [ArgFloat n1 _, ArgFloat n2 _, output] =
  primMove (boolConstant $ n1==n2) output
simplifyOp "fcmp" ["ne"] [ArgFloat n1 _, ArgFloat n2 _, output] =
  primMove (boolConstant $ n1/=n2) output
simplifyOp "fcmp" ["slt"] [ArgFloat n1 _, ArgFloat n2 _, output] =
  primMove (boolConstant $ n1<n2) output
simplifyOp "fcmp" ["sle"] [ArgFloat n1 _, ArgFloat n2 _, output] =
  primMove (boolConstant $ n1<=n2) output
simplifyOp "fcmp" ["sgt"] [ArgFloat n1 _, ArgFloat n2 _, output] =
  primMove (boolConstant $ n1>n2) output
simplifyOp "fcmp" ["sge"] [ArgFloat n1 _, ArgFloat n2 _, output] =
  primMove (boolConstant $ n1>=n2) output
simplifyOp name flags args = PrimForeign "llvm" name flags args


boolConstant :: Bool -> PrimArg
boolConstant bool = ArgInt (fromIntegral $ fromEnum bool) boolType

----------------------------------------------------------------
--                                  Logging
----------------------------------------------------------------

-- |Log a message, if we are logging body building activity.
logBuild :: String -> BodyBuilder ()
logBuild s = lift $ logMsg BodyBuilder s
