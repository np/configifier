{-# LANGUAGE DataKinds                                #-}
{-# LANGUAGE OverlappingInstances                     #-}
{-# LANGUAGE OverloadedStrings                        #-}
{-# LANGUAGE TypeOperators                            #-}
{-# LANGUAGE ScopedTypeVariables                      #-}
{-# LANGUAGE Rank2Types                               #-}
{-# LANGUAGE GADTs                                    #-}

module Data.ConfigifierSpec
where

import Data.Dynamic
import Data.Either
import Data.Maybe
import Data.Monoid
import Data.String.Conversions
import Prelude
import Test.Hspec

import qualified Data.Aeson as Aeson

import Data.Configifier as Configifier

import Test.Arbitrary ()


tests :: IO ()
tests = hspec spec

spec :: Spec
spec = describe "Configifier" $ do
    miscSpec
    selectSpec
    mergeSpec
    sourcesSpec

miscSpec :: Spec
miscSpec = do
  describe "misc" $ do
    it "simple" $
        let text :: SBS
            want :: (c ~ ToConfigCode ("bla" :> Int)) => Tagged c

            text = "bla: 3"
            want = Tagged $ Id 3

         in run text want

    it "descriptions" $
        let text :: SBS
            want :: ( c ~ ToConfigCode ("bla" :> Int :>: "describe stuff!")
                    , c' ~ NoDesc c
                    ) => Tagged c'

            text = "bla: 3"
            want = Tagged $ Id 3

         in run text want

    it "option" $
        let text :: SBS
            want :: (c ~ ToConfigCode (Maybe ("bla" :> Int))) => Tagged c

            text = "bla: 3"
            want = Tagged $ JustO (Id 3)

         in run text want

    it "option, no sources" $
        let have :: (c ~ ToConfigCode (Maybe ("bla" :> Int))) => Configifier.Result c
            want :: (c ~ ToConfigCode (Maybe ("bla" :> Int))) => Tagged c

            have = configify []
            want = Tagged NothingO

         in have `shouldBe` Right want

    it "yaml cannot parse empty cfg files (even if all config data is optional!)" $
        let text1, text2, text3 :: SBS

            text1 = ""
            text2 = " \n\t \n\t"
            text3 = " \n\t# comments are also nothing\n\t\n...\n"

            want :: (c ~ ToConfigCode (Maybe ("bla" :> Int))) => Either Error (TaggedM c) -> Bool
            want = isLeft

            f sbs = parseConfigFile sbs `shouldSatisfy` want

         in mapM_ f [text1, text2, text3]

    it "option, missing in non-empty cfg file" $
        let text :: SBS
            want :: (c ~ ToConfigCode ("org" :> Int :- Maybe ("bla" :> Int))) => Tagged c

            text = "org: 3"
            want = Tagged (Id 3 :- NothingO)

         in run text want

    it "something more nested" $
        let text1, text2 :: SBS
            want1, want2 ::
                ( c  ~ ToConfigCode c'
                , c' ~ ("frontend" :> sc :- Maybe ("backend" :> sc))
                , sc ~ ("bind_port" :> Int :- Maybe ("expose_host" :> ST))
                ) => Tagged c

            text1 = cs . unlines $
                      "frontend:" :
                      "  bind_port: 3" :
                      "  expose_host: host" :
                      "backend:" :
                      "  bind_port: 4" :
                      "  expose_host: hist" :
                      []
            text2 = cs . unlines $
                      "frontend:" :
                      "  bind_port: 3" :
                      []

            want1 = Tagged $ Id (Id 3 :- JustO (Id "host"))
                          :- JustO (Id (Id 4 :- JustO (Id "hist")))
            want2 = Tagged $ Id (Id 3 :- NothingO)
                          :- NothingO

         in run text1 want1 >> run text2 want2

    it "lists" $
        let text :: SBS
            want :: ( c ~ ToConfigCode ("bla" :> [Bool])
                    , c' ~ NoDesc c
                    ) => Tagged c'

            text = "bla: [yes, no]"
            want = Tagged $ Id [True, False]

         in run text want


run :: forall cfg tm ti .
      ( tm ~ TaggedM cfg
      , ti ~ Tagged cfg
      , Show tm, Eq tm, Show ti, Eq ti
      , Monoid tm
      , Freeze cfg
      , Aeson.FromJSON tm
      , Aeson.ToJSON tm
      , HasParseShellEnv cfg
      , HasParseCommandLine cfg
      , CanonicalizePartial cfg
      ) => SBS -> ti -> IO ()
run text parsedWant = do
    let f :: SBS -> Either Error ti
        f sbs = configify [ConfigFileYaml sbs]

    f text `shouldBe` Right parsedWant
    f (renderConfigFile parsedWant) `shouldBe` Right parsedWant


selectSpec :: Spec
selectSpec = do
  describe "select" $ do
    it "(\"l\" :> Int)" $
        let t :: forall c . (c ~ ToConfigCode ("l" :> Int)) => IO ()
            t = cfg >>. (Proxy :: Proxy '["l"]) `shouldBe` 3
              where
                cfg :: Tagged c = Tagged $ Id 3
         in t

    it "(\"l\" :> (\"l'\" :> Bool))" $
        let t :: forall c . (c ~ ToConfigCode ("l" :> ("l'" :> Bool))) => IO ()
            t = do
                  cfg >>. (Proxy :: Proxy '["l"]) `shouldBe` Id False
                  cfg >>. (Proxy :: Proxy '["l", "l'"]) `shouldBe` False
              where
                cfg :: Tagged c = Tagged . Id . Id $ False
         in t

    it "(\"l\" :> Int :- \"l'\" :> Bool)" $
        let t :: forall c . (c ~ ToConfigCode ("l" :> Int :- "l'" :> Bool)) => IO ()
            t = do
                  cfg >>. (Proxy :: Proxy '["l"]) `shouldBe` 0
                  cfg >>. (Proxy :: Proxy '["l'"]) `shouldBe` False
              where
                cfg :: Tagged c = Tagged $ Id 0 :- Id False
         in t

    it "(Maybe (\"l\" :> Int))" $
        let t :: forall c . (c ~ ToConfigCode (Maybe ("l" :> Int))) => IO ()
            t = do
                  cfg >>. (Proxy :: Proxy '["l"]) `shouldBe` Just 0
              where
                cfg :: Tagged c = Tagged $ JustO (Id 0)
         in t

    it "(Maybe (\"l\" :> Maybe (\"l'\" :> Int)))" $
        let t :: forall c . (c ~ ToConfigCode (Maybe ("l" :> Maybe ("l'" :> Int)))) => IO ()
            t = do
                  cfg1 >>. (Proxy :: Proxy '["l", "l'"]) `shouldBe` Just (Just 0)
                  cfg2 >>. (Proxy :: Proxy '["l", "l'"]) `shouldBe` Just Nothing
                  cfg3 >>. (Proxy :: Proxy '["l", "l'"]) `shouldBe` Nothing
              where
                cfg1 :: Tagged c = Tagged $ JustO (Id (JustO (Id 0)))
                cfg2 :: Tagged c = Tagged $ JustO (Id NothingO)
                cfg3 :: Tagged c = Tagged $ NothingO
         in t

    it "(\"l\" :> Int :- \"l'\" :> Int)" $
        let t :: forall c . ( c ~ ToConfigCode ("l" :> Int :- "l'" :> Int)
                            , ToVal c '["l"] ~ Just Int  -- (redundant)
                            , ToConfig c Id ~ (Id Int :- Id Int)  -- (redundant)
                            ) => IO ()
            t = do
                  cfg1 >>. (Proxy :: Proxy '["l"])  `shouldBe` 3
                  cfg1 >>. (Proxy :: Proxy '["l'"]) `shouldBe` 0
                  cfg2 >>. (Proxy :: Proxy '["l'"]) `shouldBe` 0
              where
                cfg1 :: Tagged c = Tagged $ Id 3 :- Id (0 :: Int)
                cfg2 :: Tagged c = Tagged $ Id 4 :- Id (0 :: Int)
         in t

    it "(\"l\" :> Int :- Maybe (\"l'\" :> Int))" $
        let t :: forall c . ( c ~ ToConfigCode ("l" :> Int :- Maybe ("l'" :> Int))
                            , ToVal c '["l"] ~ Just Int  -- (redundant)
                            , ToConfig c Id ~ (Id Int :- MaybeO (Id Int))  -- (redundant)
                            ) => IO ()
            t = do
                  cfg1 >>. (Proxy :: Proxy '["l"])  `shouldBe` 3
                  cfg1 >>. (Proxy :: Proxy '["l'"]) `shouldBe` (Just 0)
                  cfg2 >>. (Proxy :: Proxy '["l'"]) `shouldBe` Nothing
              where
                cfg1 :: Tagged c = Tagged $ Id 3 :- JustO (Id (0 :: Int))
                cfg2 :: Tagged c = Tagged $ Id 4 :- NothingO
         in t


mergeSpec :: Spec
mergeSpec = describe "instance Monoid (ToConfigCode *)" $
        let cfg1, cfg2, cfg3, cfg4, cfg5 ::
                ( c  ~ ToConfigCode c'
                , c' ~ Maybe ("frontend" :> sc' :- Maybe ("backend" :> sc'))
                , sc' ~ ("bind_port" :> Int :- Maybe ("expose_host" :> ST))
                ) => TaggedM c

            cfg1 = TaggedM . JustO $
                      Just (Just 3 :- JustO (Just "host"))
                   :- JustO (Just (Just 4 :- JustO (Just "hist")))
            cfg2 = TaggedM . JustO $
                      Just (Just 3 :- NothingO)
                   :- JustO (Just (Just 4 :- NothingO))
            cfg3 = TaggedM . JustO $
                      Just (Just 3 :- NothingO)
                   :- NothingO
            cfg4 = TaggedM NothingO

            cfg5 = TaggedM . JustO $
                      Just (Just 1 :- JustO (Just "ast"))
                   :- JustO (Just (Just 5 :- JustO (Just "hust")))
        in do
            -- JustO wins over NothingO

            it "1" $ (cfg1 <> cfg1) `shouldBe` cfg1
            it "2" $ (cfg1 <> cfg2) `shouldBe` cfg1
            it "3" $ (cfg1 <> cfg3) `shouldBe` cfg1
            it "4" $ (cfg1 <> cfg4) `shouldBe` cfg1

            it "5" $ (cfg2 <> cfg1) `shouldBe` cfg1
            it "6" $ (cfg3 <> cfg1) `shouldBe` cfg1
            it "7" $ (cfg4 <> cfg1) `shouldBe` cfg1

            -- right JustO wins over left JustO

            it "8" $ (cfg1 <> cfg5) `shouldBe` cfg5


sourcesSpec :: Spec
sourcesSpec = describe "sources" $
    let f :: ( c  ~ ToConfigCode c'
             , c' ~ ("frontend" :> sc :- Maybe ("backend" :> sc))
             , sc ~ ("bind_port" :> Int :- Maybe ("expose_host" :> ST))
             ) => [Source] -> Result c
        f = configify

        configFile1 :: Source = ConfigFileYaml . cs . unlines $
              "frontend:" :
              "  bind_port: 3" :
              "  expose_host: host" :
              "backend:" :
              "  bind_port: 4" :
              "  expose_host: hist" :
              []
        configFile2 :: Source = ConfigFileYaml . cs . unlines $
              "frontend:" :
              "  bind_port: 3" :
              []

        shellEnv1 :: Source = ShellEnv [("FRONTEND_BIND_PORT", "18")]
        shellEnv2 :: Source = ShellEnv [("BACKEND_EXPOSE_HOST", "bom")]

        commandLine1 :: Source = CommandLine ["--frontend-bind-port", "31"]
        commandLine2 :: Source = CommandLine ["--backend-exposte-host=mab"]

    in do
        it "parseArgs" $
            parseArgs (["--arg=31", "--flob", "gluh"] :: Args) `shouldBe` Right ([("ARG", "31"), ("FLOB", "gluh")] :: Env)

        it "1" $
            f [configFile1] `shouldBe`
                (Right . Tagged $ Id (Id 3 :- JustO (Id "host"))
                               :- JustO (Id (Id 4 :- JustO (Id "hist"))))

        it "2" $
            f [configFile1, shellEnv1, shellEnv2] `shouldBe`
                (Right . Tagged $ Id (Id 18 :- JustO (Id "host"))
                               :- JustO (Id (Id 4 :- JustO (Id "bom"))))

        it "3" $
            f [configFile1, shellEnv1, shellEnv2, commandLine1] `shouldBe`
                (Right . Tagged $ Id (Id 31 :- JustO (Id "host"))
                               :- JustO (Id (Id 4 :- JustO (Id "bom"))))
