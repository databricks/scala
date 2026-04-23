/*
 * Scala (https://www.scala-lang.org)
 *
 * Copyright EPFL and Lightbend, Inc.
 *
 * Licensed under Apache License 2.0
 * (http://www.apache.org/licenses/LICENSE-2.0).
 *
 * See the NOTICE file distributed with this work for
 * additional information regarding copyright ownership.
 */

package scala
package reflect
package internal

trait InfoTransformers {
  self: SymbolTable =>

  /* Syncnote: This should not need to be protected, as reflection does not run in multiple phases.
   */
  abstract class InfoTransformer {
    var prev: InfoTransformer = this
    var next: InfoTransformer = this

    val pid: Phase#Id
    val changesBaseClasses: Boolean
    def transform(sym: Symbol, tpe: Type): Type

    def insert(that: InfoTransformer) {
      assert(this.pid != that.pid, this.pid)

      if (that.pid < this.pid) {
        prev insert that
      } else if (next.pid <= that.pid && next.pid != NoPhase.id) {
        next insert that
      } else {
        log("Inserting info transformer %s following %s".format(phaseOf(that.pid), phaseOf(this.pid)))
        that.next = next
        that.prev = this
        next.prev = that
        this.next = that
      }
    }

    /** The InfoTransformer whose (pid == from).
     *  If no such exists, the InfoTransformer with the next
     *  higher pid.
     */
    // OPT The original formulation was recursive, but the recursive calls traverse the
    //     `prev`/`next` links of the doubly-linked list, so the receiver object changes with
    //     each call and `@tailrec` cannot be applied.  Rewrite as an explicit loop that
    //     advances `cur` along the chain; this turns the method into tight field accesses
    //     + integer compares and eliminates one stack frame per link traversed.
    def nextFrom(from: Phase#Id): InfoTransformer = {
      var cur: InfoTransformer = this
      while (true) {
        val cpid = cur.pid
        if (from == cpid) return cur
        else if (from < cpid) {
          val p = cur.prev
          if (p.pid < from) return cur
          cur = p
        } else {
          val n = cur.next
          if (n.pid == NoPhase.id) return n
          cur = n
        }
      }
      null // unreachable
    }
  }
}

