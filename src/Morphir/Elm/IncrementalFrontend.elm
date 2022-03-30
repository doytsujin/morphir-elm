module Morphir.Elm.IncrementalFrontend exposing (..)

{-| Apply all file changes to the repo in one step.
-}

import Dict exposing (Dict)
import Elm.Parser
import Elm.Processing as Processing exposing (ProcessContext)
import Elm.RawFile as RawFile
import Elm.Syntax.Declaration exposing (Declaration(..))
import Elm.Syntax.Expression as Expression exposing (Expression(..))
import Elm.Syntax.File exposing (File)
import Elm.Syntax.ModuleName as Elm
import Elm.Syntax.Node as Node exposing (Node(..))
import Elm.Syntax.Pattern as Pattern exposing (Pattern)
import Elm.Syntax.TypeAnnotation exposing (TypeAnnotation(..))
import Morphir.Dependency.DAG as DAG exposing (CycleDetected(..), DAG)
import Morphir.Elm.Frontend.Mapper as Mapper
import Morphir.Elm.IncrementalResolve as IncrementalResolve
import Morphir.Elm.ModuleName as ElmModuleName
import Morphir.Elm.ParsedModule as ParsedModule exposing (ParsedModule)
import Morphir.Elm.WellKnownOperators as WellKnownOperators
import Morphir.File.FileChanges as FileChanges exposing (Change(..), FileChanges)
import Morphir.File.Path exposing (Path)
import Morphir.IR as IR
import Morphir.IR.FQName as FQName exposing (FQName, fQName)
import Morphir.IR.Literal as Literal
import Morphir.IR.Module exposing (ModuleName)
import Morphir.IR.Name as Name exposing (Name)
import Morphir.IR.Package exposing (PackageName)
import Morphir.IR.Path as Path
import Morphir.IR.QName as QName
import Morphir.IR.Repo as Repo exposing (Repo, SourceCode, withAccessControl)
import Morphir.IR.SDK.Basics as SDKBasics
import Morphir.IR.SDK.List as List
import Morphir.IR.Type as Type exposing (Type)
import Morphir.IR.Value as Value
import Morphir.SDK.ResultList as ResultList
import Morphir.Type.Infer as Infer
import Parser
import Set exposing (Set)


type alias Errors =
    List Error


type Error
    = ModuleCycleDetected ModuleName ModuleName
    | TypeCycleDetected Name Name
    | ValueCycleDetected FQName FQName
    | InvalidModuleName ElmModuleName.ModuleName
    | ParseError Path (List Parser.DeadEnd)
    | RepoError Repo.Errors
    | MappingError Mapper.Errors
      -- need to track where the problem occurred
      -- add source location information
    | TypeInferenceError Infer.TypeError
    | ValueTypeInferenceError Infer.ValueTypeError
    | ResolveError ModuleName IncrementalResolve.Error


applyFileChanges : FileChanges -> Repo -> Result Errors Repo
applyFileChanges fileChanges repo =
    parseElmModules fileChanges
        |> Result.andThen (orderElmModulesByDependency repo)
        |> Result.andThen
            (\parsedModules ->
                parsedModules
                    |> List.foldl
                        (\( moduleName, parsedModule ) repoResultForModule ->
                            repoResultForModule
                                |> Result.andThen (processModule moduleName parsedModule)
                        )
                        (Ok repo)
            )


processModule : ModuleName -> ParsedModule -> Repo -> Result (List Error) Repo
processModule moduleName parsedModule repo =
    let
        typeNames : List Name
        typeNames =
            extractTypeNames parsedModule

        localNames : IncrementalResolve.VisibleNames
        localNames =
            { types = Set.fromList typeNames
            , constructors = Set.empty
            , values = Set.empty
            }

        resolveTypeName : IncrementalResolve.KindOfName -> List String -> String -> Result Errors FQName
        resolveTypeName kindOfName modName localName =
            parsedModule
                |> RawFile.imports
                |> IncrementalResolve.resolveImports repo
                |> Result.andThen
                    (\resolvedImports ->
                        IncrementalResolve.resolveLocalName
                            repo
                            moduleName
                            localNames
                            resolvedImports
                            modName
                            kindOfName
                            localName
                    )
                |> Result.mapError (ResolveError moduleName >> List.singleton)
    in
    extractTypes (resolveTypeName IncrementalResolve.Type) parsedModule
        |> Result.andThen (orderTypesByDependency repo.packageName moduleName)
        |> Result.andThen
            (List.foldl
                (\( typeName, typeDef ) repoResultForType ->
                    repoResultForType
                        |> Result.andThen (processType moduleName typeName typeDef)
                )
                (Ok repo)
            )


processType : ModuleName -> Name -> Type.Definition () -> Repo -> Result (List Error) Repo
processType moduleName typeName typeDef repo =
    repo
        |> Repo.insertType moduleName typeName typeDef
        |> Result.mapError (RepoError >> List.singleton)


{-| convert New or Updated Elm modules into ParsedModules for further processing
-}
parseElmModules : FileChanges -> Result Errors (List ParsedModule)
parseElmModules fileChanges =
    fileChanges
        |> Dict.toList
        |> List.filterMap
            (\( path, content ) ->
                case content of
                    Insert source ->
                        Just ( path, source )

                    Update source ->
                        Just ( path, source )

                    Delete ->
                        Nothing
            )
        |> List.map parseSource
        |> ResultList.keepAllErrors


{-| Converts an elm source into a ParsedModule.
-}
parseSource : ( Path, String ) -> Result Error ParsedModule
parseSource ( path, content ) =
    Elm.Parser.parse content
        |> Result.mapError (ParseError path)


orderElmModulesByDependency : Repo -> List ParsedModule -> Result Errors (List ( ModuleName, ParsedModule ))
orderElmModulesByDependency repo parsedModules =
    let
        parsedModuleByName : Dict ModuleName ParsedModule
        parsedModuleByName =
            parsedModules
                |> List.filterMap
                    (\parsedModule ->
                        ParsedModule.moduleName parsedModule
                            |> ElmModuleName.toIRModuleName repo.packageName
                            |> Maybe.map
                                (\moduleName ->
                                    ( moduleName
                                    , parsedModule
                                    )
                                )
                    )
                |> Dict.fromList

        foldFunction : ParsedModule -> Result Errors (DAG ModuleName) -> Result Errors (DAG ModuleName)
        foldFunction parsedModule graph =
            let
                validateIfModuleExistInPackage : ModuleName -> Bool
                validateIfModuleExistInPackage modName =
                    Path.isPrefixOf repo.packageName modName

                moduleDependencies : Set ModuleName
                moduleDependencies =
                    ParsedModule.importedModules parsedModule
                        |> List.filterMap
                            (\modName ->
                                ElmModuleName.toIRModuleName repo.packageName modName
                            )
                        |> Set.fromList

                insertEdge : ModuleName -> ModuleName -> Result Errors (DAG ModuleName) -> Result Errors (DAG ModuleName)
                insertEdge fromModuleName toModule dag =
                    dag
                        |> Result.andThen
                            (\graphValue ->
                                graphValue
                                    |> DAG.insertEdge fromModuleName toModule
                                    |> Result.mapError
                                        (\err ->
                                            case err of
                                                _ ->
                                                    [ ModuleCycleDetected fromModuleName toModule ]
                                        )
                            )

                elmModuleName =
                    ParsedModule.moduleName parsedModule
            in
            elmModuleName
                |> ElmModuleName.toIRModuleName repo.packageName
                |> Result.fromMaybe [ InvalidModuleName elmModuleName ]
                |> Result.andThen
                    (\fromModuleName ->
                        graph
                            |> Result.andThen
                                (DAG.insertNode fromModuleName moduleDependencies
                                    >> Result.mapError (\(DAG.CycleDetected from to) -> [ ModuleCycleDetected from to ])
                                )
                    )
    in
    parsedModules
        |> List.foldl foldFunction (Ok DAG.empty)
        |> Result.map
            (\graph ->
                graph
                    |> DAG.backwardTopologicalOrdering
                    |> List.concat
                    |> List.filterMap
                        (\moduleName ->
                            parsedModuleByName
                                |> Dict.get moduleName
                                |> Maybe.map (Tuple.pair moduleName)
                        )
            )


extractTypeNames : ParsedModule -> List Name
extractTypeNames parsedModule =
    let
        withWellKnownOperators : ProcessContext -> ProcessContext
        withWellKnownOperators context =
            List.foldl Processing.addDependency context WellKnownOperators.wellKnownOperators

        initialContext : ProcessContext
        initialContext =
            Processing.init |> withWellKnownOperators

        extractTypeNamesFromFile : File -> List Name
        extractTypeNamesFromFile file =
            file.declarations
                |> List.filterMap
                    (\node ->
                        case Node.value node of
                            CustomTypeDeclaration typ ->
                                typ.name |> Node.value |> Just

                            AliasDeclaration typeAlias ->
                                typeAlias.name |> Node.value |> Just

                            _ ->
                                Nothing
                    )
                |> List.map Name.fromString
    in
    parsedModule
        |> Processing.process initialContext
        |> extractTypeNamesFromFile


extractTypes : (List String -> String -> Result Errors FQName) -> ParsedModule -> Result Errors (List ( Name, Type.Definition () ))
extractTypes resolveTypeName parsedModule =
    let
        declarationsInParsedModule : List Declaration
        declarationsInParsedModule =
            parsedModule
                |> ParsedModule.declarations
                |> List.map Node.value

        typeNameToDefinition : Result Errors (List ( Name, Type.Definition () ))
        typeNameToDefinition =
            declarationsInParsedModule
                |> List.filterMap typeDeclarationToDefinition
                |> ResultList.keepAllErrors
                |> Result.mapError List.concat

        typeDeclarationToDefinition : Declaration -> Maybe (Result Errors ( Name, Type.Definition () ))
        typeDeclarationToDefinition declaration =
            case declaration of
                CustomTypeDeclaration customType ->
                    let
                        typeParams : List Name
                        typeParams =
                            customType.generics
                                |> List.map (Node.value >> Name.fromString)

                        constructorsResult : Result Errors (Type.Constructors ())
                        constructorsResult =
                            customType.constructors
                                |> List.map
                                    (\(Node _ constructor) ->
                                        let
                                            constructorName : Name
                                            constructorName =
                                                constructor.name
                                                    |> Node.value
                                                    |> Name.fromString

                                            constructorArgsResult : Result Errors (List ( Name, Type () ))
                                            constructorArgsResult =
                                                constructor.arguments
                                                    |> List.indexedMap
                                                        (\index arg ->
                                                            Mapper.mapTypeAnnotation resolveTypeName arg
                                                                |> Result.map
                                                                    (\argType ->
                                                                        ( [ "arg", String.fromInt (index + 1) ]
                                                                        , argType
                                                                        )
                                                                    )
                                                        )
                                                    |> ResultList.keepAllErrors
                                                    |> Result.mapError List.concat
                                        in
                                        constructorArgsResult
                                            |> Result.map
                                                (\constructorArgs ->
                                                    ( constructorName, constructorArgs )
                                                )
                                    )
                                |> ResultList.keepAllErrors
                                |> Result.map Dict.fromList
                                |> Result.mapError List.concat
                    in
                    constructorsResult
                        |> Result.map
                            (\constructors ->
                                ( customType.name |> Node.value |> Name.fromString
                                , Type.customTypeDefinition typeParams (withAccessControl True constructors)
                                )
                            )
                        |> Just

                AliasDeclaration typeAlias ->
                    let
                        typeParams : List Name
                        typeParams =
                            typeAlias.generics
                                |> List.map (Node.value >> Name.fromString)
                    in
                    typeAlias.typeAnnotation
                        |> Mapper.mapTypeAnnotation resolveTypeName
                        |> Result.map
                            (\tpe ->
                                ( typeAlias.name
                                    |> Node.value
                                    |> Name.fromString
                                , Type.TypeAliasDefinition typeParams tpe
                                )
                            )
                        |> Just

                _ ->
                    Nothing
    in
    typeNameToDefinition


{-| Order types topologically by their dependencies. The purpose of this function is to allow us to insert the types
into the repo in the right order without causing dependency errors.
-}
orderTypesByDependency : PackageName -> ModuleName -> List ( Name, Type.Definition () ) -> Result Errors (List ( Name, Type.Definition () ))
orderTypesByDependency thisPackageName thisModuleName unorderedTypeDefinitions =
    let
        -- This dictionary will allow us to correlate back each type definition to their names after we ordered the names
        typeDefinitionsByName : Dict Name (Type.Definition ())
        typeDefinitionsByName =
            unorderedTypeDefinitions
                |> Dict.fromList

        -- Helper function to collect all references of a type definition
        collectReferences : Type.Definition () -> Set FQName
        collectReferences typeDef =
            case typeDef of
                Type.TypeAliasDefinition _ typeExp ->
                    Type.collectReferences typeExp

                Type.CustomTypeDefinition _ accessControlledConstructors ->
                    accessControlledConstructors.value
                        |> Dict.values
                        |> List.concat
                        |> List.map (Tuple.second >> Type.collectReferences)
                        |> List.foldl Set.union Set.empty

        -- We only need to take into account local type references when ordering them
        keepLocalTypesOnly : Set FQName -> Set Name
        keepLocalTypesOnly allTypeNames =
            allTypeNames
                |> Set.filter
                    (\( packageName, moduleName, _ ) ->
                        packageName == thisPackageName && moduleName == thisModuleName
                    )
                |> Set.map (\( _, _, typeName ) -> typeName)

        -- Build the dependency graph of type names
        buildDependencyGraph : Result (CycleDetected Name) (DAG Name)
        buildDependencyGraph =
            unorderedTypeDefinitions
                |> List.foldl
                    (\( nextTypeName, typeDef ) dagResultSoFar ->
                        dagResultSoFar
                            |> Result.andThen
                                (\dagSoFar ->
                                    dagSoFar
                                        |> DAG.insertNode nextTypeName
                                            (typeDef
                                                |> collectReferences
                                                |> keepLocalTypesOnly
                                            )
                                )
                    )
                    (Ok DAG.empty)
    in
    buildDependencyGraph
        |> Result.mapError (\(CycleDetected from to) -> [ TypeCycleDetected from to ])
        |> Result.map
            (\typeDependencies ->
                typeDependencies
                    |> DAG.backwardTopologicalOrdering
                    |> List.concat
                    |> List.filterMap
                        (\typeName ->
                            typeDefinitionsByName
                                |> Dict.get typeName
                                |> Maybe.map (Tuple.pair typeName)
                        )
            )


extractValueNames : ParsedModule -> List Name
extractValueNames parsedModule =
    Debug.todo "implement this"



-- collectValueNames *
-- extractValues
-- resolve names --without types
-- topologicalOrdering
-- infer and verify type signatures


{-| Extract value definitions
-}
extractValues : (List String -> String -> Result (List IncrementalResolve.Error) FQName) -> ParsedModule -> Result Errors (List ( Name, Value.Definition () () ))
extractValues resolveValueName parsedModule =
    let
        -- get function name
        -- get function implementation
        -- get function expression
        declarationsAsDefintionsResult : Result Errors (Dict FQName (Value.Definition () ()))
        declarationsAsDefintionsResult =
            ParsedModule.declarations parsedModule
                |> Mapper.mapDeclarationsToValue resolveValueName parsedModule
                |> Result.mapError (MappingError >> List.singleton)
                |> Result.map Dict.fromList

        -- create ordered value names
        orderedValueNameResult : Result Errors (List FQName)
        orderedValueNameResult =
            declarationsAsDefintionsResult
                |> Result.andThen
                    (Dict.toList
                        >> List.foldl
                            (\( fQName, def ) dagResultSoFar ->
                                let
                                    refs =
                                        Value.collectReferences def.body
                                in
                                dagResultSoFar
                                    |> Result.andThen (DAG.insertNode fQName refs)
                            )
                            (Ok DAG.empty)
                        >> Result.mapError
                            (\(DAG.CycleDetected fNode tNode) ->
                                [ ValueCycleDetected fNode tNode ]
                            )
                        >> Result.map DAG.backwardTopologicalOrdering
                        >> Result.map List.concat
                    )

        orderedDeclarationAsDefinitions : Result Errors (List ( Name, Value.Definition () () ))
        orderedDeclarationAsDefinitions =
            orderedValueNameResult
                |> Result.andThen
                    (\fqNames ->
                        declarationsAsDefintionsResult
                            |> Result.map (Tuple.pair fqNames)
                    )
                |> Result.map
                    (\( fqNames, defs ) ->
                        List.foldl
                            (\fqName listSoFar ->
                                case Dict.get fqName defs of
                                    Just def ->
                                        let
                                            ( _, _, name ) =
                                                fqName
                                        in
                                        List.append listSoFar [ ( name, def ) ]

                                    Nothing ->
                                        listSoFar
                            )
                            []
                            fqNames
                    )
    in
    orderedDeclarationAsDefinitions



--mapElmExpressionToMorphirValue


{-| Insert or update a single module in the repo passing the source code in.
-}
mergeModuleSource : ModuleName -> SourceCode -> Repo -> Result Errors Repo
mergeModuleSource moduleName sourceCode repo =
    Debug.todo "implement"
