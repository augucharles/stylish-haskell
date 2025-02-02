--------------------------------------------------------------------------------
{-# LANGUAGE ImportQualifiedPost                       #-}
module Hasklean.Parse
    ( parseModule
    ) where


--------------------------------------------------------------------------------
import Data.Char                                       ( toLower )
import Data.List                                       ( foldl', stripPrefix )
import Data.Maybe                                      ( catMaybes, fromMaybe, listToMaybe, mapMaybe )
import Data.Traversable                                ( for )
import GHC.Data.StringBuffer qualified as GHC
import GHC.Driver.Config.Parser qualified as GHC
import GHC.Driver.Ppr
    as GHC                                             ( showSDoc )
import GHC.Driver.Session qualified as GHC
import GHC.LanguageExtensions.Type qualified as LangExt
import GHC.Parser.Header qualified as GHC
import GHC.Parser.Lexer qualified as GHC
import GHC.Types.SrcLoc qualified as GHC
import GHC.Utils.Error qualified as GHC
import Language.Haskell.GhclibParserEx.GHC.Driver.Session qualified as GHCEx
import Language.Haskell.GhclibParserEx.GHC.Parser qualified as GHCEx


--------------------------------------------------------------------------------
import Hasklean.GHC                                    ( baseDynFlags )
import Hasklean.Module                                 ( Module )


--------------------------------------------------------------------------------
type Extensions = [String]


--------------------------------------------------------------------------------
data ParseExtensionResult
    -- | Actual extension, and whether we want to turn it on or off.
    = ExtensionOk LangExt.Extension Bool
    -- | Failed to parse extension.
    | ExtensionError String
    -- | Other LANGUAGE things that aren't really extensions, like 'Safe'.
    | ExtensionIgnore


--------------------------------------------------------------------------------
parseExtension :: String -> ParseExtensionResult
parseExtension str
    | Just x <- GHCEx.readExtension str = ExtensionOk x True
    | 'N' : 'o' : str' <- str           = case parseExtension str' of
        ExtensionOk x onOff -> ExtensionOk x (not onOff)
        result              -> result
    | map toLower str `elem` ignores    = ExtensionIgnore
    | otherwise                         = ExtensionError $
        "Unknown extension: " ++ show str
  where
    ignores = ["unsafe", "trustworthy", "safe"]


--------------------------------------------------------------------------------
-- | Filter out lines which use CPP macros
unCpp :: String -> String
unCpp = unlines . go False . lines
  where
    go _           []       = []
    go isMultiline (x : xs) =
        let isCpp         = isMultiline || listToMaybe x == Just '#'
            nextMultiline = isCpp && not (null x) && last x == '\\'
        in (if isCpp then "" else x) : go nextMultiline xs


--------------------------------------------------------------------------------
-- | If the given string is prefixed with an UTF-8 Byte Order Mark, drop it
-- because haskell-src-exts can't handle it.
dropBom :: String -> String
dropBom ('\xfeff' : str) = str
dropBom str              = str


--------------------------------------------------------------------------------
-- | Abstraction over GHC lib's parsing
parseModule :: Extensions -> Maybe FilePath -> String -> Either String Module
parseModule externalExts0 fp string = do
    -- Parse extensions.
    externalExts1 <- fmap catMaybes . for externalExts0 $ \str -> case parseExtension str of
        ExtensionError err  -> Left err
        ExtensionIgnore     -> pure Nothing
        ExtensionOk x onOff -> pure $ Just (x, onOff)

    -- Build first dynflags.
    let dynFlags0 = foldl' toggleExt baseDynFlags externalExts1

    -- Parse options from file
    let fileOptions = fmap GHC.unLoc $ snd $ GHC.getOptions (GHC.initParserOpts dynFlags0)
            (GHC.stringToStringBuffer string)
            (fromMaybe "-" fp)
        fileExtensions = mapMaybe (\str -> do
            str' <- stripPrefix "-X" str
            case parseExtension str' of
                ExtensionOk x onOff -> Just (x, onOff)
                _                   -> Nothing)
            fileOptions

    -- Set further dynflags.
    let dynFlags1 = foldl' toggleExt dynFlags0 fileExtensions
            `GHC.gopt_set` GHC.Opt_KeepRawTokenStream

    -- Possibly strip CPP.
    let removeCpp s = if GHC.xopt LangExt.Cpp dynFlags1 then unCpp s else s
        input = removeCpp $ dropBom string

    -- Actual parse.
    case GHCEx.parseModule input dynFlags1 of
        GHC.POk _ m -> Right m
        GHC.PFailed ps -> Left . withFileName . GHC.showSDoc dynFlags1 . GHC.pprMessages . snd $
            GHC.getPsMessages ps
  where
    withFileName x = maybe "" (<> ": ") fp <> x

    toggleExt dynFlags (ext, onOff) = foldl'
        toggleExt
        ((if onOff then GHC.xopt_set else GHC.xopt_unset) dynFlags ext)
        [(rhs, onOff') | (lhs, onOff', rhs) <- GHC.impliedXFlags, lhs == ext]
