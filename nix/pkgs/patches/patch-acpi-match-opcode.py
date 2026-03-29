#!/usr/bin/env python3
"""Patch the vendored acpi crate to implement the AML Match opcode (0x89).

Match is DefMatch := MatchOp SearchPkg MatchOpcode Operand MatchOpcode Operand StartIndex
where MatchOpcode is a raw byte interleaved between TermArgs.

The implementation uses multi-phase parsing:
  Phase 1 (1 arg):  collect SearchPkg TermArg
  Phase 2 (3 args): read MatchOp1 byte, collect Operand1 TermArg
  Phase 3 (6 args): read MatchOp2 byte, collect Operand2 + StartIndex TermArgs, execute search

Usage: python3 patch-acpi-match-opcode.py <vendor-directory>
  Finds acpi-* crate dir and patches src/aml/mod.rs.
"""
import sys
import os
import glob


def main():
    vendor_dir = sys.argv[1]

    # Find the acpi crate in vendor directory
    acpi_dirs = glob.glob(os.path.join(vendor_dir, "acpi-*"))
    if not acpi_dirs:
        # Try without version suffix (git deps sometimes omit it)
        acpi_dirs = [os.path.join(vendor_dir, "acpi")]
        if not os.path.isdir(acpi_dirs[0]):
            print("ERROR: acpi crate not found in vendor directory: " + vendor_dir)
            sys.exit(1)

    acpi_dir = acpi_dirs[0]
    aml_file = os.path.join(acpi_dir, "src", "aml", "mod.rs")

    if not os.path.exists(aml_file):
        print("ERROR: " + aml_file + " not found")
        sys.exit(1)

    print("Patching " + aml_file)

    with open(aml_file, "r") as f:
        content = f.read()

    # 1. Remove DefMatch from TODO list
    content = content.replace(" *  - DefMatch\n", "")

    # 2. Replace the Opcode::Match => todo!() with Phase 1 start
    old_match_todo = """                /*
                 * TODO
                 * Match is a difficult opcode to parse, as it interleaves dynamic arguments and
                 * random bytes that need to be extracted as you go. I think we'll need to use 1+
                 * internal in-flight ops to parse the static bytedatas as we go, and then retire
                 * the real op at the end.
                 */
                Opcode::Match => todo!(),"""

    new_match_start = """                Opcode::Match => {
                    // Start multi-phase Match parsing. The stream after 0x89 is:
                    //   SearchPkg(TermArg) MatchOp1(byte) Operand1(TermArg) MatchOp2(byte) Operand2(TermArg) StartIndex(TermArg)
                    // Phase 1 collects SearchPkg. The retirement handler reads interleaved bytes.
                    context.start(OpInFlight::new(Opcode::Match, &[ResolveBehaviour::TermArg]));
                }"""

    if old_match_todo not in content:
        print("ERROR: Could not find Match todo!() block to replace")
        sys.exit(1)
    content = content.replace(old_match_todo, new_match_start)

    # 3. Add Match retirement handler before the catch-all panic
    old_panic = '                    _ => panic!("Unexpected operation has created in-flight op!"),'

    new_match_handler = """                    Opcode::Match => {
                        self.do_match(&mut context, op)?;
                    }
                    _ => panic!("Unexpected operation has created in-flight op!"),"""

    if old_panic not in content:
        print("ERROR: Could not find catch-all panic to insert Match handler before")
        sys.exit(1)
    content = content.replace(old_panic, new_match_handler)

    # 4. Add do_match and match_compare methods before parse_field_list
    old_parse_field = "    fn parse_field_list("

    new_methods = """    /// Execute one phase of the Match opcode's multi-phase parsing.
    ///
    /// Match (0x89) interleaves raw bytes between TermArgs:
    ///   SearchPkg(TermArg) MatchOp1(byte) Operand1(TermArg) MatchOp2(byte) Operand2(TermArg) StartIndex(TermArg)
    ///
    /// Phase 1 (n=1): SearchPkg collected. Read MatchOp1 byte, start Phase 2 for Operand1.
    /// Phase 2 (n=3): Operand1 collected. Read MatchOp2 byte, start Phase 3 for Operand2 + StartIndex.
    /// Phase 3 (n=6): All args collected. Execute the search and return result.
    fn do_match(&self, context: &mut MethodContext, op: OpInFlight) -> Result<(), AmlError> {
        let n = op.arguments.len();

        if n == 1 || n == 3 {
            // Intermediate phase: read the next MatchOpcode byte from the stream,
            // then start the next phase to collect the following TermArg(s).
            let match_op_byte = context.next()?;
            let mut args = op.arguments;
            args.push(Argument::ByteData(match_op_byte));

            if args.len() == 2 {
                // Phase 1 -> 2: have [SearchPkg, MatchOp1], need Operand1
                context.start(OpInFlight::new_with(
                    Opcode::Match,
                    args,
                    &[
                        ResolveBehaviour::Placeholder,
                        ResolveBehaviour::Placeholder,
                        ResolveBehaviour::TermArg,
                    ],
                ));
            } else {
                // Phase 2 -> 3: have [SearchPkg, MatchOp1, Operand1, MatchOp2], need Operand2 + StartIndex
                context.start(OpInFlight::new_with(
                    Opcode::Match,
                    args,
                    &[
                        ResolveBehaviour::Placeholder,
                        ResolveBehaviour::Placeholder,
                        ResolveBehaviour::Placeholder,
                        ResolveBehaviour::Placeholder,
                        ResolveBehaviour::TermArg,
                        ResolveBehaviour::TermArg,
                    ],
                ));
            }
            Ok(())
        } else if n == 6 {
            // Final phase: all six arguments collected, perform the match search.
            //   [0] SearchPkg: Package
            //   [1] MatchOp1:  ByteData (0=MTR, 1=MEQ, 2=MLE, 3=MLT, 4=MGE, 5=MGT)
            //   [2] Operand1:  Integer
            //   [3] MatchOp2:  ByteData
            //   [4] Operand2:  Integer
            //   [5] StartIndex: Integer
            let result = {
                let (search_pkg, match_op1, operand1, match_op2, operand2, start_index) =
                    match &op.arguments[..] {
                        [Argument::Object(pkg), Argument::ByteData(op1), Argument::Object(val1), Argument::ByteData(op2), Argument::Object(val2), Argument::Object(start)] => {
                            (pkg, *op1, val1, *op2, val2, start)
                        }
                        _ => panic!("Match: unexpected argument types"),
                    };

                let pkg = search_pkg.clone().unwrap_transparent_reference();
                let elements = match &*pkg {
                    Object::Package(elems) => elems,
                    other => {
                        return Err(AmlError::ObjectNotOfExpectedType {
                            expected: ObjectType::Package,
                            got: other.typ(),
                        });
                    }
                };

                let operand1_val = operand1.as_integer()?;
                let operand2_val = operand2.as_integer()?;
                let start = start_index.as_integer()? as usize;

                // Search the package from StartIndex for an element satisfying both conditions
                let mut found = u64::MAX; // ONES = no match
                for (i, elem) in elements.iter().enumerate().skip(start) {
                    let elem_val = match elem.clone().unwrap_transparent_reference().as_integer() {
                        Ok(v) => v,
                        Err(_) => continue, // Skip non-integer elements per spec
                    };

                    if Self::match_compare(match_op1, elem_val, operand1_val)
                        && Self::match_compare(match_op2, elem_val, operand2_val)
                    {
                        found = i as u64;
                        break;
                    }
                }
                found
            };

            context.contribute_arg(Argument::Object(Object::Integer(result).wrap()));
            context.retire_op(op);
            Ok(())
        } else {
            panic!("Match: unexpected argument count {}", n);
        }
    }

    /// Compare an element value against an operand using a Match operator byte.
    ///
    /// Match operators (ACPI spec 20.2.5.4):
    ///   0 (MTR) - Always true
    ///   1 (MEQ) - True if element == operand
    ///   2 (MLE) - True if element <= operand
    ///   3 (MLT) - True if element < operand
    ///   4 (MGE) - True if element >= operand
    ///   5 (MGT) - True if element > operand
    fn match_compare(op_byte: u8, element: u64, operand: u64) -> bool {
        match op_byte {
            0 => true,
            1 => element == operand,
            2 => element <= operand,
            3 => element < operand,
            4 => element >= operand,
            5 => element > operand,
            _ => {
                warn!("Match: invalid match opcode byte {}, treating as no-match", op_byte);
                false
            }
        }
    }

    fn parse_field_list("""

    if old_parse_field not in content:
        print("ERROR: Could not find parse_field_list insertion point")
        sys.exit(1)
    content = content.replace(old_parse_field, new_methods, 1)

    with open(aml_file, "w") as f:
        f.write(content)

    print("Match opcode implementation patched successfully")


if __name__ == "__main__":
    main()
