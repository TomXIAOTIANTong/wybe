

--  File     : Config.hs
--  RCS      : $Id$
--  Author   : Peter Schachte
--  Origin   : Sat Feb 18 00:38:48 2012
--  Purpose  : Configuration for wybe compiler
--  Copyright: (c) 2012 Peter Schachte.  All rights reserved.

-- |Compiler configuration parameters.  These may vary between
--  OSes.
module Config (sourceExtension, objectExtension, executableExtension,
               interfaceExtension, bitcodeExtension, sharedLibs,
                                 ldArgs, ldSystemArgs)
    where

-- |The file extension for source files.
sourceExtension :: String
sourceExtension = "wybe"

-- |The file extension for object files.
objectExtension :: String
objectExtension = "o"

-- |The file extension for executable files.
executableExtension :: String
executableExtension = ""

-- |The file extension for interface files.
interfaceExtension :: String
interfaceExtension = "int"

-- |The file extension for bitcode files
bitcodeExtension :: String
bitcodeExtension = "bc"

-- |Foreign shared library directory name
sharedLibDirName :: String
sharedLibDirName = "lib/"

sharedLibs :: [FilePath]
sharedLibs = ["cbits.so"]

ldArgs :: [String]
ldArgs = ["-demangle", "-dynamic"]

ldSystemArgs :: [String]
ldSystemArgs =
    [ "-arch", "x86_64",
      "-macosx_version_min", "10.11.0",
      "-syslibroot",
      "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX10.11.sdk",
      "-lSystem",
      "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/../lib/clang/7.0.2/lib/darwin/libclang_rt.osx.a"
    ]
