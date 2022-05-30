{-
   Copyright 2020 Morgan Stanley

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.
-}


module Morphir.Spark.AST exposing
    ( ObjectExpression(..), Expression(..), DataFrame
    , objectExpressionFromValue
    , Error, NamedExpressions
    )

{-| An abstract-syntax tree for Spark. This is a custom built AST that focuses on the subset of Spark features that our
generator uses.


# Abstract Syntax Tree

@docs ObjectExpression, Expression, NamedExpression, DataFrame


# Create

@docs objectExpressionFromValue, namedExpressionFromValue, expressionFromValue

-}

import Array exposing (Array)
import Morphir.IR as IR exposing (..)
import Morphir.IR.FQName as FQName exposing (FQName)
import Morphir.IR.Literal exposing (Literal)
import Morphir.IR.Name as Name exposing (Name)
import Morphir.IR.Type exposing (Type)
import Morphir.IR.Value as Value exposing (TypedValue)
import Morphir.SDK.ResultList as ResultList


{-| An ObjectExpression represents a transformation that is applied directly to a Spark Data Frame.
Like in the case of df.select(...), df.filter(...), df.groupBy(...); these expressions apply a transformation step
to the data within a Data Frame. They are also referred to as **Transformations** within spark.
ObjectExpressions produce DataFrames as output, making chaining of these transformations possible and for this reason,
ObjectExpression is expressed as a recursive type.

These are the supported Transformations:

  - **From**
      - Specifies a source that other ObjectExpressions can be applied on
      - The general assumption is that all sources are spark DataFrames
  - **Filter**
      - Represents a `df.filter(...)` transformation to be applied on DataFrame ObjectExpression.
      - The two arguments are: the ColumnExpression and the ObjectExpression to apply a filter on.
  - **Select**
      - Represents a `df.select(...)` transformation.
      - The two arguments are:
          - A List of (Name, Expression) which represent a alias for a column expression and a column expression
            like `col(name)` within spark.
          - A target ObjectExpression from which to select.

-}
type ObjectExpression
    = From ObjectName
    | Filter Expression ObjectExpression
    | Select NamedExpressions ObjectExpression


{-| An Expression represents an column expression.
Expressions produce a value that is usually of type `Column` in spark. ,
An Expression could take in a `Column` type or `Any` type as input and also produce a Column type and for this reason,
Expression is expressed as a recursive type.

These are the supported Expressions:

  - **Column**
      - Specifies the name of a column in a DataFrame similar to the `col("name")` in spark
  - **Literal**
      - Represents a literal value like `1`, `"Hello"`, `2.3`.
  - **Variable**
      - Represents a variable name like `param`.
  - **BinaryOperation**
      - BinaryOperations represent binary operations like `1 + 2`.
      - The three arguments are: the operator, the left hand side expression, and the right hand side expression
  - **WhenOtherwise**
      - Represent a `when(expression, result).otherwise(expression, result)` in spark.
      - It maps directly to an IfElse statement and can be chained.
      - The three arguments are: the condition, the Then expression evaluated if the condition passes, and the Else expression.
  - **Apply**
      - Applies a list of arguments on a function.
      - The two arguments are: The fully qualified name of the function to invoke, and a list of arguments to invoke the function with

-}
type Expression
    = Column String
    | Literal Literal
    | Variable String
    | BinaryOperation String Expression Expression
    | WhenOtherwise Expression Expression Expression
    | Apply FQName (List Expression)


{-| A List of (Name, Expression) where each Name represents an alias for a column expression,
and the Expression is a column expression like `col(name)` within spark that gets aliased.
-}
type alias NamedExpressions =
    List ( Name, Expression )


{-| A representation of an acceptable DataFrame structure
-}
type alias DataFrame =
    { schema : List FieldName
    , data : List (Array Expression)
    }


type alias ObjectName =
    Name


type alias FieldName =
    Name


type Error
    = UnhandledValue TypedValue
    | FunctionNotFound FQName
    | UnsupportedOperatorReference FQName
    | LambdaExpected TypedValue
    | ReferenceExpected


{-| provides a way to create ObjectExpressions from a Morphir Value.
This is where support for various top level expression is added. This function fails to produce an ObjectExpression
when it encounters a value that is not supported.
-}
objectExpressionFromValue : IR -> TypedValue -> Result Error ObjectExpression
objectExpressionFromValue ir morphirValue =
    case morphirValue of
        Value.Variable _ varName ->
            From varName |> Ok

        Value.Apply _ (Value.Apply _ (Value.Reference _ ( [ [ "morphir" ], [ "s", "d", "k" ] ], [ [ "list" ] ], [ "filter" ] )) predicate) sourceRelation ->
            objectExpressionFromValue ir sourceRelation
                |> Result.andThen
                    (\source ->
                        expressionFromValue ir predicate
                            |> Result.map (\fieldExp -> Filter fieldExp source)
                    )

        Value.Apply _ (Value.Apply _ (Value.Reference _ ( [ [ "morphir" ], [ "s", "d", "k" ] ], [ [ "list" ] ], [ "map" ] )) mappingFunction) sourceRelation ->
            objectExpressionFromValue ir sourceRelation
                |> Result.andThen
                    (\source ->
                        namedExpressionsFromValue ir mappingFunction
                            |> Result.map (\expr -> Select expr source)
                    )

        other ->
            let
                _ =
                    Debug.log "Relational.Backend.mapValue unhandled" other
            in
            Err (UnhandledValue other)


{-| Provides a way to create NamedExpressions from a Morphir Value.
-}
namedExpressionsFromValue : IR -> TypedValue -> Result Error NamedExpressions
namedExpressionsFromValue ir typedValue =
    case typedValue of
        Value.Lambda _ _ (Value.Record _ fields) ->
            fields
                |> List.map
                    (\( name, value ) ->
                        expressionFromValue ir value
                            |> Result.map (Tuple.pair name)
                    )
                |> ResultList.keepFirstError

        Value.FieldFunction _ name ->
            expressionFromValue ir typedValue
                |> Result.map (Tuple.pair name >> List.singleton)

        _ ->
            LambdaExpected typedValue |> Err


{-| Provides a way to create Expressions from a Morphir Value.
This is where support for various column expression is added. This function fails to produce an Expression
when it encounters a value that is not supported.
-}
expressionFromValue : IR -> TypedValue -> Result Error Expression
expressionFromValue ir morphirValue =
    case morphirValue of
        Value.Literal _ literal ->
            Literal literal |> Ok

        Value.Variable _ name ->
            Name.toCamelCase name |> Variable |> Ok

        Value.Field _ _ name ->
            Name.toCamelCase name |> Column |> Ok

        Value.FieldFunction _ name ->
            Name.toCamelCase name |> Column |> Ok

        Value.Lambda _ _ body ->
            expressionFromValue ir body

        Value.Apply _ _ _ ->
            case morphirValue of
                Value.Apply _ (Value.Apply _ (Value.Reference _ (( package, modName, _ ) as ref)) arg) argValue ->
                    case ( package, modName ) of
                        ( [ [ "morphir" ], [ "s", "d", "k" ] ], [ [ "basics" ] ] ) ->
                            Result.map3
                                BinaryOperation
                                (binaryOpString ref)
                                (expressionFromValue ir arg)
                                (expressionFromValue ir argValue)

                        _ ->
                            collectArgValues morphirValue []
                                |> Result.andThen
                                    (\( args, fqn ) ->
                                        lookupFQName ir fqn
                                            |> Result.map
                                                (\def ->
                                                    inlineArguments def.inputTypes args def.body
                                                )
                                    )
                                |> Result.andThen (expressionFromValue ir)

                _ ->
                    collectArgValues morphirValue []
                        |> Result.andThen
                            (\( args, fqn ) ->
                                lookupFQName ir fqn
                                    |> Result.map
                                        (\def ->
                                            inlineArguments def.inputTypes args def.body
                                        )
                            )
                        |> Result.andThen (expressionFromValue ir)

        Value.Reference _ fqName ->
            case IR.lookupValueDefinition fqName ir of
                Just def ->
                    expressionFromValue ir def.body

                Nothing ->
                    FunctionNotFound fqName |> Err

        Value.IfThenElse _ cond thenBranch elseBranch ->
            Result.map3
                WhenOtherwise
                (expressionFromValue ir cond)
                (expressionFromValue ir thenBranch)
                (expressionFromValue ir elseBranch)

        other ->
            UnhandledValue other |> Err


collectArgValues : TypedValue -> List TypedValue -> Result Error ( List TypedValue, FQName )
collectArgValues v argsSoFar =
    case v of
        Value.Apply _ body a ->
            collectArgValues body (a :: argsSoFar)

        Value.Reference _ fqn ->
            Ok ( argsSoFar, fqn )

        _ ->
            Err ReferenceExpected


{-| A utility function that looks up a value definition within the IR
-}
lookupFQName : IR -> FQName -> Result Error (Value.Definition () (Type ()))
lookupFQName ir fQName =
    case IR.lookupValueDefinition fQName ir of
        Just def ->
            Ok def

        Nothing ->
            FunctionNotFound fQName |> Err


{-| A utility function that replaces variables in a function with their values.
-}
inlineArguments : List ( Name, va, Type ta ) -> List TypedValue -> TypedValue -> TypedValue
inlineArguments paramList argList fnBody =
    let
        overwriteValue : Name -> TypedValue -> TypedValue -> TypedValue
        overwriteValue searchTerm replacement scope =
            -- TODO handle replacement of the variable within a lambda
            case scope of
                Value.Apply a target ((Value.Variable _ name) as var) ->
                    if name == searchTerm then
                        -- Replace variable if the name matches the searchTerm
                        Value.Apply a
                            (overwriteValue searchTerm replacement target)
                            replacement

                    else
                        -- Name does not match. Maintain variable
                        Value.Apply a
                            (overwriteValue searchTerm replacement target)
                            var

                Value.Apply a target arg ->
                    Value.Apply a
                        (overwriteValue searchTerm replacement target)
                        (overwriteValue searchTerm replacement arg)

                _ ->
                    scope
    in
    paramList
        |> List.map2 Tuple.pair argList
        |> List.foldl
            (\( arg, ( varName, _, _ ) ) body ->
                overwriteValue varName arg body
            )
            fnBody


{-| A simple mapping for a Morphir.SDK:Basics binary operations to it's spark string equivalent
-}
binaryOpString : FQName -> Result Error String
binaryOpString fQName =
    case FQName.toString fQName of
        "Morphir.SDK:Basics:equal" ->
            Ok "==="

        "Morphir.SDK:Basics:notEqual" ->
            Ok "=!="

        "Morphir.SDK:Basics:add" ->
            Ok "+"

        "Morphir.SDK:Basics:subtract" ->
            Ok "-"

        "Morphir.SDK:Basics:multiply" ->
            Ok "*"

        "Morphir.SDK:Basics:divide" ->
            Ok "/"

        "Morphir.SDK:Basics:power" ->
            Ok "pow"

        "Morphir.SDK:Basics:modBy" ->
            Ok "mod"

        "Morphir.SDK:Basics:remainderBy" ->
            Ok "%"

        "Morphir.SDK:Basics:logBase" ->
            Ok "log"

        "Morphir.SDK:Basics:atan2" ->
            Ok "atan2"

        "Morphir.SDK:Basics:lessThan" ->
            Ok "<"

        "Morphir.SDK:Basics:greaterThan" ->
            Ok ">"

        "Morphir.SDK:Basics:lessThanOrEqual" ->
            Ok "<="

        "Morphir.SDK:Basics:greaterThanOrEqual" ->
            Ok ">="

        "Morphir.SDK:Basics:max" ->
            Ok "max"

        "Morphir.SDK:Basics:min" ->
            Ok "min"

        "Morphir.SDK:Basics:and" ->
            Ok "and"

        "Morphir.SDK:Basics:or" ->
            Ok "or"

        "Morphir.SDK:Basics:xor" ->
            Ok "xor"

        _ ->
            UnsupportedOperatorReference fQName |> Err
