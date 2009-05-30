module Database.TxtSushi.Util.CommandLineArgument (
    extractCommandLineArguments,
    formatCommandLine,
    CommandLineDescription(CommandLineDescription),
    options,
    minTailArgumentCount,
    tailArgumentNames,
    tailArgumentCountIsFixed,
    OptionDescription(OptionDescription),
    isRequired,
    optionFlag,
    argumentNames,
    minArgumentCount,
    argumentCountIsFixed) where

import Data.List
import Data.Map (Map)
import qualified Data.Map as Map
--import Test.HUnit

data CommandLineDescription = CommandLineDescription {
    options :: [OptionDescription],
    
    minTailArgumentCount :: Int,
    
    tailArgumentNames :: [String],
    
    tailArgumentCountIsFixed :: Bool} deriving (Show, Eq, Ord)

-- | a data structure for describing command line arguments
data OptionDescription = OptionDescription {
    
    -- | determines if this is a required option or not
    isRequired :: Bool,
    
    {- |
    What flag should we use. Eg: "-pretty-output"
    -}
    optionFlag :: String,
    
    {- |
    The name(s) to use for the argument(s).
    -}
    argumentNames :: [String],
    
    {- |
    the minimum number of args allowed
    -}
    minArgumentCount :: Int,
    
    {- |
    if true then 'minArgumentCount' is the upper threshold
    -}
    argumentCountIsFixed :: Bool} deriving (Show, Eq, Ord)

space = " ";
etc = "...";

formatCommandLine commandLine =
    let formattedOptions = formatOptions (options commandLine)
        formattedTailArgs = formatTailArguments commandLine
    in
        if null formattedOptions || null formattedTailArgs then
            formattedOptions ++ formattedTailArgs
        else
            formattedOptions ++ space ++ formattedTailArgs

formatTailArguments commandLine =
    let tailArgs = tailArgumentNames commandLine
        minTailArgs = minTailArgumentCount commandLine
        formattedTailArgs = intercalate space (take minTailArgs (cycle tailArgs))
    in
        if tailArgumentCountIsFixed commandLine then
            formattedTailArgs
         else
            if null formattedTailArgs then etc
            else formattedTailArgs ++ space ++ etc

formatOptions :: [OptionDescription] -> String
formatOptions [] = ""
formatOptions (headOption:optionsTail) =
    let argSubstring = argumentSubstring headOption
        spacedArgSubstring = if null argSubstring then "" else space ++ argSubstring
        requiredOptionString = (optionFlag headOption) ++ spacedArgSubstring
        formattedOptionsTail = if null optionsTail then "" else space ++ (formatOptions optionsTail)
    in
        if isRequired headOption then
            requiredOptionString ++ formattedOptionsTail
        else
            "[" ++ requiredOptionString ++ "]" ++ formattedOptionsTail

argumentSubstring option =
    let minArgs = minArgumentCount option
    in
        if argumentCountIsFixed option then
            if minArgs == 0 then ""
            else intercalate space (take minArgs (cycle (argumentNames option)))
        else
            -- take care of the bounded case
            (intercalate space (take minArgs (cycle (argumentNames option)))) ++ space ++ etc

extractCommandLineArguments ::
    CommandLineDescription ->
    [String] ->
    (Map.Map OptionDescription [[String]], [String])
extractCommandLineArguments cmdLineDesc argValues =
    let unreservedArgCount = (length argValues) - (minTailArgumentCount cmdLineDesc)
        (unreservedArgs, reservedArgs) = splitAt unreservedArgCount argValues
        theOptions = options cmdLineDesc
        (optionMap, remainingArgs) = extractOptions theOptions unreservedArgs
        anyOptionsInReservedArgs =
            let (hopefullyEmptyMap, _) = extractOptions theOptions reservedArgs
            in not $ Map.null hopefullyEmptyMap
    in
        -- TODO this if else is really lame. we should replace all this
        --      along w/ error handling with status codes
        if anyOptionsInReservedArgs then
            (Map.empty, [])
        else
            (optionMap, remainingArgs ++ reservedArgs)

extractOptions ::
    [OptionDescription] ->
    [String] ->
    (Map.Map OptionDescription [[String]], [String])
extractOptions [] argValues = (Map.empty, argValues)
extractOptions _ [] = (Map.empty, [])
extractOptions optDescs argValues@(argHead:argTail) =
    case (find (\optDesc -> optionFlag optDesc == argHead) optDescs) of
        Nothing ->
            (Map.empty, argValues)
        Just optDesc ->
            let (optArgs, afterOptArgs) = extractOption optDesc optDescs argValues
                (tailArgsMap, afterTailArgs) = extractOptions optDescs afterOptArgs
            in (addOptionArgsToMap tailArgsMap optDesc optArgs, afterTailArgs)

extractOption ::
    OptionDescription ->
    [OptionDescription] ->
    [String] ->
    ([String], [String])
extractOption optDesc allOptDescs (argHead:argTail) =
    let optArgExtent = argumentExtent optDesc allOptDescs argTail
    in splitAt optArgExtent argTail

argumentExtent :: OptionDescription -> [OptionDescription] -> [String] -> Int
argumentExtent optionDescription allOptDescs afterOptArgs =
    let allOptFlags = map optionFlag allOptDescs
        maybeNextArgIndex = findIndex (\arg -> any (== arg) allOptFlags) afterOptArgs
        minArgCount = minArgumentCount optionDescription
        isFixed = argumentCountIsFixed optionDescription
    in
        case maybeNextArgIndex of
            Nothing ->
                let afterOptLength = length afterOptArgs
                in
                    if afterOptLength < minArgCount then missingParameters
                    else if isFixed then minArgCount
                    else afterOptLength
            Just nextArgIndex ->
                if nextArgIndex < minArgCount then missingParameters
                else if isFixed then minArgCount
                else nextArgIndex
    where
        missingParameters =
            error $ "missing parameter(s) for " ++ (optionFlag optionDescription)

addOptionArgsToMap ::
    Map.Map OptionDescription [[String]] ->
    OptionDescription ->
    [String] ->
    Map.Map OptionDescription [[String]]
addOptionArgsToMap optArgMap opt args =
    case (Map.lookup opt optArgMap) of
        Nothing ->          Map.insert opt [args] optArgMap
        Just currArgs ->    Map.insert opt (currArgs ++ [args]) optArgMap

-- Test code
{-
byNameOption = OptionDescription
    False       -- isRequired
    "-by-name"  -- optionFlag
    []          -- argumentNames
    0           -- minArgumentCount
    True        -- argumentCountIsFixed

helpOption = OptionDescription
    False       -- isRequired
    "-help"     -- optionFlag
    []          -- argumentNames
    0           -- minArgumentCount
    True        -- argumentCountIsFixed

fancyPantsOption = OptionDescription
    False           -- isRequired
    "-fancy"        -- optionFlag
    ["f1", "f2"]    -- argumentNames
    2               -- minArgumentCount
    False           -- argumentCountIsFixed

cmdLineOps1 = [byNameOption, helpOption, fancyPantsOption]

cmdLineDesc1 = CommandLineDescription
    cmdLineOps1 -- options
    1           -- minTailArgumentCount
    "file/-"    -- tailArgumentNames
    True        -- tailArgumentCountIsFixed
cmdLine1 = ["-by-name", "-fancy", "f1arg", "f2arg", "-help", "-"]
parsedCmd1 = extractOptions (options cmdLineDesc1) cmdLine1

test1 = TestCase $ assertEqual
    "options test" cmdLineOps1 (options cmdLineDesc1)
-}
