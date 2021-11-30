{-# OPTIONS_GHC -Wno-orphans #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE DeriveGeneric, DeriveAnyClass #-}
module Data.Yaml.Internal
    (
      ParseException(..)
    , prettyPrintParseException
    , Warning(..)
    , parse
    , decodeHelper
    , decodeHelper_
    , decodeAllHelper
    , decodeAllHelper_
    , textToScientific
    , stringScalar
    , defaultStringStyle
    , isSpecialString
    , specialStrings
    , isNumeric
    , objToStream
    , objToEvents
    , anyEvent
    , missed
    ) where

#if !MIN_VERSION_base(4,8,0)
import Control.Applicative ((<$>), Applicative(..))
#endif
import Control.Applicative ((<|>))
import Control.Monad.State.Strict
import Control.Monad.Reader
import Data.Aeson
#if MIN_VERSION_aeson(2,0,0)
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as M
import Data.Aeson.KeyMap (KeyMap)
#else
import qualified Data.HashMap.Strict as M
#endif
import Data.Aeson.Internal (formatError)
import Data.Aeson.Types hiding (parse, Parser)
import qualified Data.Attoparsec.Text as Atto
import Data.Bits (shiftL, (.|.))
import Data.ByteString (ByteString)
import qualified Data.ByteString.Builder as BB
import qualified Data.ByteString.Lazy as BL
import Data.ByteString.Builder.Scientific (scientificBuilder)
import Data.Char (toUpper, ord)
import Data.List (foldl', (\\))
import qualified Data.HashSet as HashSet
import           Data.Map (Map)
import qualified Data.Map as Map
import           Data.Set (Set)
import qualified Data.Set as Set
import Data.Scientific (Scientific, base10Exponent, coefficient)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (decodeUtf8With, encodeUtf8)
import Data.Text.Encoding.Error (lenientDecode)
import Data.Typeable
import qualified Data.Vector as V
import GHC.Generics (Generic)
import Control.DeepSeq

import qualified Text.Libyaml as Y
import Text.Libyaml hiding (encode, decode, encodeFile, decodeFile)

import           Control.Exception.Safe

import           Streamly.Prelude (SerialT)
import Streamly.Internal.Data.Parser (Parser)
import qualified Streamly.Internal.Data.Parser as Parser
import qualified Streamly.Internal.Data.Stream.IsStream.Eliminate as Stream
import Streamly.Internal.Data.Parser.ParserK.Type (toParserK)
import qualified Streamly.Internal.Data.Parser.ParserD.Type as ParserD
#if MIN_VERSION_streamly(0,8,1)
import Streamly.Internal.Data.Stream.IsStream.Lift (hoist)
#else
import Streamly.Internal.Data.Parser.ParserK.Type (fromParserK, fromEffect)
import Streamly.Internal.Data.Stream.StreamK (hoist)
#endif




#if MIN_VERSION_aeson(2,0,0)
fromText :: T.Text -> K.Key
fromText = K.fromText

toText :: K.Key -> T.Text
toText = K.toText
#else
fromText :: T.Text -> T.Text
fromText = id

toText :: Key -> T.Text
toText = id

type KeyMap a = M.HashMap Text a
type Key = Text
#endif

data ParseException = NonScalarKey
                    | UnknownAlias { _anchorName :: Y.AnchorName }
                    | UnexpectedEvent { _received :: Maybe Event
                                      , _expected :: Maybe Event
                                      }
                    | InvalidYaml (Maybe YamlException)
                    | MultipleDocuments
                    | AesonException String
                    | OtherParseException SomeException
                    | NonStringKey JSONPath
                    | NonStringKeyAlias Y.AnchorName Value
                    | CyclicIncludes
                    | LoadSettingsException FilePath ParseException
    deriving (Show, Typeable, Generic, NFData)

instance NFData SomeException where rnf !_ = ()

instance Exception ParseException where
#if MIN_VERSION_base(4, 8, 0)
  displayException = prettyPrintParseException
#endif

-- | Alternative to 'show' to display a 'ParseException' on the screen.
--   Instead of displaying the data constructors applied to their arguments,
--   a more textual output is returned. For example, instead of printing:
--
-- > InvalidYaml (Just (YamlParseException {yamlProblem = "did not find expected ',' or '}'", yamlContext = "while parsing a flow mapping", yamlProblemMark = YamlMark {yamlIndex = 42, yamlLine = 2, yamlColumn = 12}})))
--
--   It looks more pleasant to print:
--
-- > YAML parse exception at line 2, column 12,
-- > while parsing a flow mapping:
-- > did not find expected ',' or '}'
--
-- Since 0.8.11
prettyPrintParseException :: ParseException -> String
prettyPrintParseException pe = case pe of
  NonScalarKey -> "Non scalar key"
  UnknownAlias anchor -> "Unknown alias `" ++ anchor ++ "`"
  UnexpectedEvent { _expected = mbExpected, _received = mbUnexpected } -> unlines
    [ "Unexpected event: expected"
    , "  " ++ show mbExpected
    , "but received"
    , "  " ++ show mbUnexpected
    ]
  InvalidYaml mbYamlError -> case mbYamlError of
    Nothing -> "Unspecified YAML error"
    Just yamlError -> case yamlError of
      YamlException s -> "YAML exception:\n" ++ s
      YamlParseException problem context mark -> concat
        [ "YAML parse exception at line " ++ show (yamlLine mark) ++
          ", column " ++ show (yamlColumn mark)
        , case context of
            "" -> ":\n"
            -- The context seems to include a leading "while" or similar.
            _  -> ",\n" ++ context ++ ":\n"
        , problem
        ]
  MultipleDocuments -> "Multiple YAML documents encountered"
  AesonException s -> "Aeson exception:\n" ++ s
  OtherParseException exc -> "Generic parse exception:\n" ++ show exc
  NonStringKey path -> formatError path "Non-string keys are not supported"
  NonStringKeyAlias anchor value -> unlines
    [ "Non-string key alias:"
    , "  Anchor name: " ++ anchor
    , "  Value: " ++ show value
    ]
  CyclicIncludes -> "Cyclic includes"
  LoadSettingsException fp exc -> "Could not parse file as YAML: " ++ fp ++ "\n" ++ prettyPrintParseException exc


defineAnchor :: Value -> String -> Parser (ReaderT JSONPath Parse) Event ()
defineAnchor value name = modify (modifyAnchors $ Map.insert name value)
  where
    modifyAnchors :: (Map String Value -> Map String Value) -> ParseState -> ParseState
    modifyAnchors f st =  st {parseStateAnchors = f (parseStateAnchors st)}

lookupAnchor :: String -> Parser (ReaderT JSONPath Parse) Event (Maybe Value)
lookupAnchor name = gets (Map.lookup name . parseStateAnchors)

data Warning = DuplicateKey !JSONPath
    deriving (Eq, Show)

addWarning :: Warning -> Parser (ReaderT JSONPath Parse) Event ()
addWarning w = modify (modifyWarnings (w :))
  where
    modifyWarnings :: ([Warning] -> [Warning]) -> ParseState -> ParseState
    modifyWarnings f st =  st {parseStateWarnings = f (parseStateWarnings st)}

data ParseState = ParseState {
  parseStateAnchors  :: Map String Value
, parseStateWarnings :: [Warning]
}

type Parse = StateT ParseState IO

requireEvent :: Event -> Parser (ReaderT JSONPath Parse) Event ()
requireEvent e = do
    f <- toParserK anyEvent
    unless (f == Just e) $ missed (Just e)

{-# INLINE anyEvent #-}
anyEvent :: MonadCatch m => ParserD.Parser m a (Maybe a)
anyEvent = ParserD.Parser step initial extract
  where
  initial = pure $ ParserD.IPartial ()
  step _ a = pure $ ParserD.Done 0 (Just a)
  extract _ = pure Nothing


parse :: Parser (ReaderT JSONPath Parse) Event Value
parse = do
    docs <- parseAll
    case docs of
        [] -> return Null
        [doc] -> return doc
        _ -> liftIO $ throwIO MultipleDocuments


parseAll :: Parser (ReaderT JSONPath Parse) Event [Value]
parseAll = do
    e <- toParserK anyEvent
    case e of
      Nothing -> return []
      Just EventStreamStart ->
        parseDocs
      _ -> missed e

parseDocs :: Parser (ReaderT JSONPath Parse) Event [Value]
parseDocs = do
  e <- toParserK anyEvent
  case e of
      Just EventStreamEnd -> return []
      Just EventDocumentStart -> do
          res <- parseO
          requireEvent EventDocumentEnd
          (res :) <$> parseDocs
      _ -> missed e

missed :: (MonadIO m, MonadThrow m) => Maybe Event -> Parser m a b
missed event = liftIO $ throwIO $ UnexpectedEvent event Nothing


parseScalar :: ByteString -> Anchor -> Style -> Tag
            -> Parser (ReaderT JSONPath Parse) Event Text
parseScalar v a style tag = do
    let res = decodeUtf8With lenientDecode v
    mapM_ (defineAnchor (textToValue style tag res)) a
    return res


textToValue :: Style -> Tag -> Text -> Value
textToValue SingleQuoted _ t = String t
textToValue DoubleQuoted _ t = String t
textToValue _ StrTag t = String t
textToValue Folded _ t = String t
textToValue _ _ t
    | t `elem` ["null", "Null", "NULL", "~", ""] = Null
    | any (t `isLike`) ["y", "yes", "on", "true"] = Bool True
    | any (t `isLike`) ["n", "no", "off", "false"] = Bool False
    | Right x <- textToScientific t = Number x
    | otherwise = String t
  where x `isLike` ref = x `elem` [ref, T.toUpper ref, titleCased]
          where titleCased = toUpper (T.head ref) `T.cons` T.tail ref

textToScientific :: Text -> Either String Scientific
textToScientific = Atto.parseOnly (num <* Atto.endOfInput)
  where
    num = (fromInteger <$> ("0x" *> Atto.hexadecimal))
      <|> (fromInteger <$> ("0o" *> octal))
      <|> Atto.scientific

    octal = T.foldl' step 0 <$> Atto.takeWhile1 isOctalDigit
      where
        isOctalDigit c = (c >= '0' && c <= '7')
        step a c = (a `shiftL` 3) .|. fromIntegral (ord c - 48)


parseO :: Parser (ReaderT JSONPath Parse) Event Value
parseO = do
    me <- toParserK anyEvent
    case me of
        Just (EventScalar v tag style a) -> textToValue style tag <$> parseScalar v a style tag
        Just (EventSequenceStart _ _ a) -> parseS 0 a id
        Just (EventMappingStart _ _ a) -> parseM mempty a M.empty
        Just (EventAlias an) -> do
            m <- lookupAnchor an
            case m of
                Nothing -> liftIO $ throwIO $ UnknownAlias an
                Just v -> return v
        _ -> missed me

parseS :: Int
       -> Y.Anchor
       -> ([Value] -> [Value])
       -> Parser (ReaderT JSONPath Parse) Event Value
parseS !n a front = do
    me <- Parser.lookAhead (toParserK anyEvent)
    case me of
        Just EventSequenceEnd -> do
            void (toParserK anyEvent)
            let res = Array $ V.fromList $ front []
            mapM_ (defineAnchor res) a
            return res
        _ -> do
            o <- local (Index n :) parseO
            parseS (succ n) a $ front . (:) o

parseM :: Set Key
       -> Y.Anchor
       -> KeyMap Value
       -> Parser (ReaderT JSONPath Parse) Event Value
parseM mergedKeys a front = do
    me <- toParserK anyEvent
    case me of
        Just EventMappingEnd -> do
            let res = Object front
            mapM_ (defineAnchor res) a
            return res
        _ -> do
            s <- case me of
                    Just (EventScalar v tag style a') -> fromText <$> parseScalar v a' style tag
                    Just (EventAlias an) -> do
                        m <- lookupAnchor an
                        case m of
                            Nothing -> liftIO $ throwIO $ UnknownAlias an
                            Just (String t) -> return $ fromText t
                            Just v -> liftIO $ throwIO $ NonStringKeyAlias an v
                    _ -> do
                        path <- ask
                        liftIO $ throwIO $ NonStringKey path

            (mergedKeys', al') <- local (Key s :) $ do
              o <- parseO
              let al = do
                      when (M.member s front && Set.notMember s mergedKeys) $ do
                          path <- reverse <$> ask
                          addWarning (DuplicateKey path)
                      return (Set.delete s mergedKeys, M.insert s o front)
              if s == "<<"
                         then case o of
                                  Object l  -> return (merge l)
                                  Array l -> return $ merge $ foldl' mergeObjects M.empty $ V.toList l
                                  _          -> al
                         else al
            parseM mergedKeys' a al'
    where mergeObjects al (Object om) = M.union al om
          mergeObjects al _           = al

          merge xs = (Set.fromList (M.keys xs \\ M.keys front), M.union front xs)


parseSrc :: Parser (ReaderT JSONPath Parse) Event val
         -> SerialT IO Event
         -> IO (val, ParseState)
parseSrc eventParser src =
  flip runStateT (ParseState Map.empty []) $
    flip runReaderT [] $
    Stream.parse eventParser (hoist liftIO src)

mkHelper :: Parser (ReaderT JSONPath Parse) Event val        -- ^ parse libyaml events as Value or [Value]
         -> (SomeException -> IO (Either ParseException a))  -- ^ what to do with unhandled exceptions
         -> ((val, ParseState) -> Either ParseException a)   -- ^ further transform and parse results
         -> SerialT IO Event                                 -- ^ the libyaml event (string/file) source
         -> IO (Either ParseException a)
mkHelper eventParser onOtherExc extractResults src = catches
    (extractResults <$> parseSrc eventParser src)
    [ Handler $ \pe -> return $ Left (pe :: ParseException)
    , Handler $ \ye -> return $ Left $ InvalidYaml $ Just (ye :: YamlException)
    , Handler $ \sae -> throwIO (sae :: SomeAsyncException)
    , Handler onOtherExc
    ]

decodeHelper :: FromJSON a
             => SerialT IO Y.Event
             -> IO (Either ParseException ([Warning], Either String a))
decodeHelper = mkHelper parse throwIO $ \(v, st) ->
    Right (parseStateWarnings st, parseEither parseJSON v)

decodeAllHelper :: FromJSON a
                => SerialT IO Event
                -> IO (Either ParseException ([Warning], Either String [a]))
decodeAllHelper = mkHelper parseAll throwIO $ \(vs, st) ->
    Right (parseStateWarnings st, mapM (parseEither parseJSON) vs)

catchLeft :: SomeException -> IO (Either ParseException a)
catchLeft = return . Left . OtherParseException

decodeHelper_ :: FromJSON a
              => SerialT IO Event
              -> IO (Either ParseException ([Warning], a))
decodeHelper_ = mkHelper parse catchLeft $ \(v, st) ->
    case parseEither parseJSON v of
        Left e -> Left $ AesonException e
        Right x -> Right (parseStateWarnings st, x)

decodeAllHelper_ :: FromJSON a
                 => SerialT IO Event
                 -> IO (Either ParseException ([Warning], [a]))
decodeAllHelper_ = mkHelper parseAll catchLeft $ \(vs, st) ->
    case mapM (parseEither parseJSON) vs of
        Left e -> Left $ AesonException e
        Right xs -> Right (parseStateWarnings st, xs)

type StringStyle = Text -> ( Tag, Style )

-- | Encodes a string with the supplied style. This function handles the empty
-- string case properly to avoid https://github.com/snoyberg/yaml/issues/24
--
-- @since 0.11.2.0
stringScalar :: StringStyle -> Maybe Text -> Text -> Event
stringScalar _ anchor "" = EventScalar "" NoTag SingleQuoted (T.unpack <$> anchor)
stringScalar stringStyle anchor s = EventScalar (encodeUtf8 s) tag style (T.unpack <$> anchor)
  where
    ( tag, style ) = stringStyle s

-- |
-- @since 0.11.2.0
defaultStringStyle :: StringStyle
defaultStringStyle = \s ->
    case () of
      ()
        | "\n" `T.isInfixOf` s -> ( NoTag, Literal )
        | isSpecialString s -> ( NoTag, SingleQuoted )
        | otherwise -> ( NoTag, PlainNoTag )

-- | Determine whether a string must be quoted in YAML and can't appear as plain text.
-- Useful if you want to use 'setStringStyle'.
--
-- @since 0.10.2.0
isSpecialString :: Text -> Bool
isSpecialString s = s `HashSet.member` specialStrings || isNumeric s

-- | Strings which must be escaped so as not to be treated as non-string scalars.
--
-- @since 0.8.32
specialStrings :: HashSet.HashSet Text
specialStrings = HashSet.fromList $ T.words
    "y Y yes Yes YES n N no No NO true True TRUE false False FALSE on On ON off Off OFF null Null NULL ~ *"

-- |
-- @since 0.8.32
isNumeric :: Text -> Bool
isNumeric = either (const False) (const True) . textToScientific

-- | Encode a value as a YAML document stream.
--
-- @since 0.11.2.0
objToStream :: ToJSON a => StringStyle -> a -> [Y.Event]
objToStream stringStyle o =
      (:) EventStreamStart
    . (:) EventDocumentStart
    $ objToEvents stringStyle o
        [ EventDocumentEnd
        , EventStreamEnd
        ]

-- | Encode a value as a list of 'Event's.
--
-- @since 0.11.2.0
objToEvents :: ToJSON a => StringStyle -> a -> [Y.Event] -> [Y.Event]
objToEvents stringStyle = objToEvents' . toJSON
  where
    objToEvents' (Array list) rest =
        EventSequenceStart NoTag AnySequence Nothing
      : foldr objToEvents' (EventSequenceEnd : rest) (V.toList list)

    objToEvents' (Object o) rest =
        EventMappingStart NoTag AnyMapping Nothing
      : foldr pairToEvents (EventMappingEnd : rest) (M.toList o)
      where
        pairToEvents :: Pair -> [Y.Event] -> [Y.Event]
        pairToEvents (k, v) = objToEvents' (String $ toText k) . objToEvents' v

    objToEvents' (String s) rest = stringScalar stringStyle Nothing s : rest

    objToEvents' Null rest = EventScalar "null" NullTag PlainNoTag Nothing : rest

    objToEvents' (Bool True) rest = EventScalar "true" BoolTag PlainNoTag Nothing : rest
    objToEvents' (Bool False) rest = EventScalar "false" BoolTag PlainNoTag Nothing : rest

    objToEvents' (Number s) rest =
      let builder
            -- Special case the 0 exponent to remove the trailing .0
            | base10Exponent s == 0 = BB.integerDec $ coefficient s
            | otherwise = scientificBuilder s
          lbs = BB.toLazyByteString builder
          bs = BL.toStrict lbs
       in EventScalar bs IntTag PlainNoTag Nothing : rest


#if !MIN_VERSION_streamly(0,8,1)
instance (MonadThrow m, MonadReader r m, MonadCatch m) => MonadReader r (Parser m a) where
    {-# INLINE ask #-}
    ask = fromEffect ask
    {-# INLINE local #-}
    local f (fromParserK -> ParserD.Parser step init' extract) =
      toParserK $ ParserD.Parser ((local f .) . step)
             (local f init')
             (local f . extract)


instance (MonadThrow m, MonadState s m) => MonadState s (Parser m a) where
    {-# INLINE get #-}
    get = fromEffect get
    {-# INLINE put #-}
    put = fromEffect . put


instance (MonadThrow m, MonadIO m) => MonadIO (Parser m a) where
    {-# INLINE liftIO #-}
    liftIO = fromEffect . liftIO
#endif
