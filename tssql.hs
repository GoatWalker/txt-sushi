-----------------------------------------------------------------------------
-- |
-- Copyright   :  (c) Keith Sheppard 2009
-- License     :  GPL3 or greater
-- Maintainer  :  keithshep@gmail.com
-- Stability   :  experimental
-- Portability :  portable
--
-- Main entry point for the TxtSushi SQL command line
--
-----------------------------------------------------------------------------
import Data.List
import Data.Version (Version(..))
import qualified Data.Map as Map
import System.Environment
import System.Exit
import System.IO

import Text.ParserCombinators.Parsec

import Database.TxtSushi.IO
import Database.TxtSushi.ParseUtil
import Database.TxtSushi.SQLExecution
import Database.TxtSushi.SQLParser
import Database.TxtSushi.Util.CommandLineArgument
import Database.TxtSushi.Util.IOUtil

import Paths_txt_sushi

helpOption :: OptionDescription
helpOption = OptionDescription {
    isRequired              = False,
    optionFlag              = "-help",
    argumentNames           = [],
    minArgumentCount        = 0,
    argumentCountIsFixed    = True}

externalSortOption :: OptionDescription
externalSortOption = OptionDescription {
    isRequired              = False,
    optionFlag              = "-external-sort",
    argumentNames           = [],
    minArgumentCount        = 0,
    argumentCountIsFixed    = True}

tableDefOption :: OptionDescription
tableDefOption = OptionDescription {
    isRequired              = False,
    optionFlag              = "-table",
    argumentNames           = ["table_name", "CSV_file_name"],
    minArgumentCount        = 2,
    argumentCountIsFixed    = True}

allOpts :: [OptionDescription]
allOpts = [helpOption, externalSortOption, tableDefOption]

sqlCmdLine :: CommandLineDescription
sqlCmdLine = CommandLineDescription {
    options                     = allOpts,
    minTailArgumentCount        = 1,
    tailArgumentNames           = ["SQL_select_statement"],
    tailArgumentCountIsFixed    = True}

validateTableNames :: [String] -> [String] -> Bool
validateTableNames [] _ = True
validateTableNames (argTblHead:argTblTail) selectTbls =
    if argTblHead `elem` selectTbls then
        validateTableNames argTblTail selectTbls
    else
        error $ "The given table name \"" ++ argTblHead ++
                "\" does not appear in the SELECT statement"

tableArgsToMap :: [[String]] -> Map.Map String String
tableArgsToMap [] = Map.empty
tableArgsToMap (currTableArgs:tailTableArgs) =
    case currTableArgs of
        [fileName, tblName] ->
            Map.insert fileName tblName (tableArgsToMap tailTableArgs)
        _ ->
            error $ "the \"" ++ (optionFlag tableDefOption) ++
                    "\" option should have exactly two arguments"

unwrapMapList :: (Monad m) => [(t, m t1)] -> m [(t, t1)]
unwrapMapList [] = return []
unwrapMapList ((key, value):mapTail) = do
    unwrappedValue <- value
    unwrappedTail <- unwrapMapList mapTail
    return $ (key, unwrappedValue):unwrappedTail

printUsage :: String -> IO ()
printUsage progName = do
    putStrLn $ progName ++ " (" ++ versionStr ++ ")"
    putStrLn $ "Usage: " ++ progName ++ " " ++ formatCommandLine sqlCmdLine
    where
        versionStr = intercalate "." (map show $ versionBranch version)

argsToSortConfig :: Map.Map OptionDescription a -> SortConfiguration
argsToSortConfig argMap =
    if Map.member externalSortOption argMap then UseExternalSort else UseInMemorySort

main :: IO ()
main = do
    args <- getArgs
    progName <- getProgName
    
    let (argMap, argTail) = extractCommandLineArguments sqlCmdLine args
        showHelp = Map.member helpOption argMap || length argTail /= 1
        parseOutcome = parse (withTrailing eof parseSelectStatement) "" (head argTail)
    
    if showHelp then printUsage progName else
        case parseOutcome of
            Left  err        -> print err
            Right selectStmt ->
                let
                    -- create a table file map from the user args
                    tableArgs = Map.findWithDefault [] tableDefOption argMap
                    tableArgMap = tableArgsToMap tableArgs
                    
                    -- get a default table to file map from the select statement
                    selectTblNames = allMaybeTableNames (maybeFromTable selectStmt)
                    defaultTblMap = Map.fromList (zip selectTblNames selectTblNames)
                    
                    -- join the two with arg values taking precidence over
                    -- the default values
                    finalTblFileMap = tableArgMap `Map.union` defaultTblMap
                in
                    -- turn the files into strings
                    if validateTableNames (Map.keys tableArgMap) selectTblNames
                        then do
                            let contentsMap = Map.map getContentsFromFileOrStdin finalTblFileMap
                            
                            unwrappedContents <- unwrapMapList $ Map.toList contentsMap
                            
                            let unwrappedContentsMap = Map.fromList unwrappedContents
                                textTableMap = Map.map (parseTable csvFormat) unwrappedContentsMap
                                dbTableMap = Map.mapWithKey textTableToDatabaseTable textTableMap
                                sortCfg = argsToSortConfig argMap
                                selectedDbTable = select sortCfg selectStmt dbTableMap
                                selectedTxtTable = databaseTableToTextTable selectedDbTable
                            
                            putStr $ formatTable csvFormat selectedTxtTable
                        else
                            exitFailure
