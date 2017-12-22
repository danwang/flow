(**
 * Copyright (c) 2013-present, Facebook, Inc.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

type binary_boolean_op =
  | And
  | Or

type sketchy_boolean_op_kind =
  | UnreachableBranch
  | ConfusingOperator

type sketchy_null_kind =
 | SketchyBool
 | SketchyString
 | SketchyNumber
 | SketchyMixed

type lint_kind =
 | SketchyBooleanOp of sketchy_boolean_op_kind * binary_boolean_op
 | SketchyNull of sketchy_null_kind
 | UntypedTypeImport
 | UntypedImport
 | NonstrictImport
 | UnclearType
 | UnsafeGettersSetters
 | DeprecatedDeclareExports

val string_of_kind: lint_kind -> string

val kinds_of_string: string -> lint_kind list option

module LintMap: MyMap.S with type key = lint_kind
module LintSet: Set.S with type elt = lint_kind
