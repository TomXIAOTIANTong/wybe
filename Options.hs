--  File     : Options.hs
--  RCS      : $Id$
--  Author   : Peter Schachte
--  Origin   : Thu Jan 19 17:15:01 2012
--  Purpose  : Handle compiler options/switches
--  Copyright: � 2012 Peter Schachte.  All rights reserved.
--
----------------------------------------------------------------
--                      Compiler Options
----------------------------------------------------------------

-- |The wybe compiler command line options.
module Options (Options(..), handleCmdline, verbose) where

import System.Console.GetOpt
import System.Environment
import System.Exit
import Version

-- |Command line options for the wybe compiler.
data Options = Options{  
    optForce         :: Bool     -- ^Compile specified files even if up to date
    , optForceAll    :: Bool     -- ^Compile all files even if up to date
    , optVerbosity   :: Int      -- ^How much debugging and progress output
    , optShowVersion :: Bool     -- ^Print compiler version and exit
    , optShowHelp    :: Bool     -- ^Print compiler help and exit
    } deriving Show

-- |Defaults for all compiler options
defaultOptions    = Options
 { optForce       = False
 , optForceAll    = False
 , optVerbosity   = 0
 , optShowVersion = False
 , optShowHelp    = False
 }

-- |Command line option parser and help text
options :: [OptDescr (Options -> Options)]
options =
 [ Option ['f'] ["force"]
     (NoArg (\ opts -> opts { optForce = True }))
   "force compilation of specified files"
 , Option [] ["force-all"]
     (NoArg (\ opts -> opts { optForceAll = True }))
   "force compilation of all dependencies"
 , Option ['v'] ["verbose"]
     (NoArg (\ opts -> opts { optVerbosity = 1 + optVerbosity opts }))
     "verbose output on stderr"
 , Option ['V'] ["version"]
     (NoArg (\ opts -> opts { optShowVersion = True }))
     "show version number"
 , Option ['h'] ["help"]
     (NoArg (\ opts -> opts { optShowHelp = True }))
     "display this help text and exit"
 ]


-- |Help text header string
header :: String
header = "Usage: wybemk [OPTION...] targets..."

-- |Parse command line arguments
compilerOpts :: [String] -> IO (Options, [String])
compilerOpts argv = 
  case getOpt Permute options argv of
    (o,n,[]  ) -> return (foldl (flip id) defaultOptions o, n)
    (_,_,errs) -> ioError (userError (concat errs ++ usageInfo header options))

-- |Was the specified verbosity level (or greater) specified?
verbose :: Int -> Options -> Bool
verbose n opts = optVerbosity opts >= n

-- |Parse the command line and handle all options asking to print 
--  something and exit.
handleCmdline :: IO (Options, [String])
handleCmdline = do
    argv <- getArgs
    (opts,files) <- compilerOpts argv
    if optShowHelp opts then do
        putStrLn $ usageInfo header options
        exitSuccess
      else if optShowVersion opts then do
               putStrLn $ "wybemk " ++ version ++ "\nBuilt " ++ buildDate
               exitSuccess
           else return (opts,files)