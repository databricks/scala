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
package util

/** A wrapper for a re-entrant, cached instance of a value of type `T`.
  *
  * Not thread safe.
  */
final class ReusableInstance[T <: AnyRef](make: () => T, enabled: Boolean) {
  private val cached = make()
  private var taken = false

  @inline def using[R](action: T => R): R =
    if (!enabled || taken) action(make())
    else try {
      taken = true
      action(cached)
    } finally taken = false

  // OPT non-functional acquire/release pair.  `using` allocates a SAM
  //     instance for `action` on every call, which shows up in the JFR
  //     allocation profile (e.g. ~150 MB / bench run for `Type.findMember`).
  //     Hot call sites can use the explicit pair instead:
  //         val t = ri.acquire()
  //         try { ... } finally ri.release(t)
  //     `release` is a no-op when `t` is a re-entrant fresh instance,
  //     since in that case the cache slot was never marked taken.
  def acquire(): T =
    if (!enabled || taken) make()
    else { taken = true; cached }

  def release(t: T): Unit =
    if (t eq cached) taken = false
}

object ReusableInstance {
  def apply[T <: AnyRef](make: => T, enabled: Boolean): ReusableInstance[T] =
    new ReusableInstance[T](make _, enabled)
}