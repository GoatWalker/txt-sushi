module Database.TxtSushi.ExternalSort (
    externalSort,
    externalSortBy,
    externalSortByConstrained,
    defaultByteQuota,
    defaultMaxOpenFiles) where

import Database.TxtSushi.IO
import Database.TxtSushi.Transform

import Data.Binary
import Data.Binary.Get
import Data.Binary.Put
import Data.Int
import qualified Data.ByteString.Lazy as BS
import Data.List
import System.IO
import System.IO.Unsafe
import System.Directory

-- | performs an external sort on the given list using the default resource
--   constraints
externalSort :: (Binary b, Ord b) => [b] -> [b]
externalSort = externalSortBy compare

-- | performs an external sort on the given list using the given comparison
--   function and the default resource constraints
externalSortBy :: (Binary b) => (b -> b -> Ordering) -> [b] -> [b]
externalSortBy = externalSortByConstrained defaultByteQuota defaultMaxOpenFiles

-- | Currently 16 MB. Don't rely on this value staying the same in future
--   releases!
defaultByteQuota :: (Integral i) => i
defaultByteQuota = 16 * 1024 * 1024

-- | Currently 16 files. Don't rely on this value staying the same in future
--   releases!
defaultMaxOpenFiles :: (Integral i) => i
defaultMaxOpenFiles = 8

-- | performs an external sort on the given list using the given resource
--   constraints
externalSortByConstrained :: (Binary b, Integral i) => i -> i -> (b -> b -> Ordering) -> [b] -> [b]
externalSortByConstrained byteQuota maxOpenFiles cmp xs = unsafePerformIO $ do
    partialSortFiles <- bufferPartialSortsBy (fromIntegral byteQuota) cmp xs
    partialSortByteStrs <- readBinFiles partialSortFiles
    
    let partialSortBinaries = map decodeAll partialSortByteStrs
    
    -- now we must merge together the partial sorts
    --return $ mergeAllBy cmp partialSortBinaries
    externalMergeAllBy (fromIntegral maxOpenFiles) cmp partialSortBinaries

-- | unwrap a list of Monad 'boxed' items
unwrapMonads [] = return []
unwrapMonads (x:xt) = do
    unwrappedHead <- x
    unwrappedTail <- unwrapMonads xt
    return (unwrappedHead:unwrappedTail)

-- | merge a list of sorted lists into a single sorted list
mergeAllBy :: (a -> a -> Ordering) -> [[a]] -> [a]
mergeAllBy _ [] = []
mergeAllBy _ [singletonList] = singletonList
mergeAllBy cmp (fstList:sndList:[]) = mergeBy cmp fstList sndList
mergeAllBy cmp listList =
    -- recurse after breking the list down by about 1/2 the size
    mergeAllBy cmp (partitionAndMerge 2 cmp listList)

-- TODO add a smart adjustment so that the last partition will not ever
--      be more than 1 element different than the others

-- | partitions the given sorted lists into groupings containing `partitionSize`
--   or fewer lists then merges each of those partitions. So the returned
--   list should normally be shorter than the given list
partitionAndMerge :: Int -> (a -> a -> Ordering) -> [[a]] -> [[a]]
partitionAndMerge _ _ [] = []
partitionAndMerge partitionSize cmp listList =
    map (mergeAllBy cmp) $ regularPartitions partitionSize listList

-- | chops up the given list at regular intervals
regularPartitions :: Int -> [a] -> [[a]]
regularPartitions _ [] = []
regularPartitions partitionSize xs =
    let (currPartition, otherXs) = splitAt partitionSize xs
    in  currPartition : regularPartitions partitionSize otherXs

-- | merge two sorted lists into a single sorted list
mergeBy :: (a -> a -> Ordering) -> [a] -> [a] -> [a]
mergeBy comparisonFunction []    list2   = list2
mergeBy comparisonFunction list1 []      = list1
mergeBy comparisonFunction list1@(head1:tail1) list2@(head2:tail2) =
    case head1 `comparisonFunction` head2 of
        GT  -> (head2:(mergeBy comparisonFunction list1 tail2))
        _   -> (head1:(mergeBy comparisonFunction tail1 list2))

externalMergeAllBy :: Binary b => Int -> (b -> b -> Ordering) -> [[b]] -> IO [b]
externalMergeAllBy _ _ [] = return []
-- TODO do i need to write singleton lists to file in order to keep the max open file promise??
externalMergeAllBy _ _ [singletonList] = return singletonList
externalMergeAllBy maxOpenFiles cmp listList = do
    -- we use (maxOpenFiles - 1) because we need to account for the file
    -- handle that we're reading from
    let mergedPartitions = partitionAndMerge (maxOpenFiles - 1) cmp listList
    
    -- Stream the results through the file system (we don't want to hold
    -- the results in memory)
    mergedBuffFiles <- unwrapMonads $ map bufferToTempFile mergedPartitions
    mergedByteStrs <- readBinFiles mergedBuffFiles
    let mergedBinaries = map decodeAll mergedByteStrs
    
    -- time to recurse
    externalMergeAllBy maxOpenFiles cmp mergedBinaries

-- | create a list of parial sorts
bufferPartialSortsBy :: (Binary b) => Int64 -> (b -> b -> Ordering) -> [b] -> IO [String]
bufferPartialSortsBy _ _ [] = return []
bufferPartialSortsBy byteQuota cmp xs = do
    let (sortNowList, sortLaterList) = splitAfterQuota byteQuota xs
        sortedRows = sortBy cmp sortNowList
    sortBuffer <- bufferToTempFile sortedRows
    otherSortBuffers <- bufferPartialSortsBy byteQuota cmp sortLaterList
    return (sortBuffer:otherSortBuffers)

-- TODO not efficiet! we're converting to binary twice so that we don't have
-- the bytestrings buffered to memory during the sort (that would about double
-- our mem usage). I think the right answer is to add a class extending binary
-- that has a sizeOf function
splitAfterQuota :: (Binary b) => Int64 -> [b] -> ([b], [b])
splitAfterQuota _ [] = ([], [])
splitAfterQuota quotaInBytes (binaryHead:binaryTail) =
    let
        quotaRemaining = quotaInBytes - BS.length (encode binaryHead)
        (fstBinsTail, sndBins) = splitAfterQuota quotaRemaining binaryTail
    in
        if quotaRemaining <= 0
        then ([binaryHead], binaryTail)
        else (binaryHead:fstBinsTail, sndBins)

-- | lazily reads the given binary files
readBinFiles :: [String] -> IO [BS.ByteString]
readBinFiles fileNames = do
    fileHandles <- unwrapMonads [openBinaryFile file ReadMode | file <- fileNames]
    byteStrs <- unwrapMonads $ map BS.hGetContents fileHandles
    return byteStrs

-- | buffer the binaries to a temporary file and return a handle to that file
bufferToTempFile :: (Binary b) => [b] -> IO String
bufferToTempFile [] = return []
bufferToTempFile xs = do
    tempDir <- getTemporaryDirectory
    (tempFilePath, tempFileHandle) <- openBinaryTempFile tempDir "sort.txt"
    
    BS.hPut tempFileHandle (encodeAll xs)
    hClose tempFileHandle
    
    return tempFilePath

encodeAll :: (Binary b) => [b] -> BS.ByteString
encodeAll = BS.concat . map encode

decodeAll :: (Binary b) => BS.ByteString -> [b]
decodeAll bs
    | BS.null bs = []
    | otherwise =
        let (decodedBin, remainingBs, _) = runGetState get bs 0
        in  decodedBin : decodeAll remainingBs