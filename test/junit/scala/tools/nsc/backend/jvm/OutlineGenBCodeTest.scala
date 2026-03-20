package scala.tools.nsc.backend.jvm

import org.junit.Assert._
import org.junit.Test
import org.junit.runner.RunWith
import org.junit.runners.JUnit4

import scala.jdk.CollectionConverters._
import scala.tools.asm.Opcodes
import scala.tools.testkit.BytecodeTesting
import scala.tools.testkit.BytecodeTesting._

@RunWith(classOf[JUnit4])
class OutlineGenBCodeTest extends BytecodeTesting {
  override def compilerArgs = "-Youtline -usejavacp"
  import compiler._

  @Test def outlineStubThrowsUoe(): Unit = {
    val c = compileClass("class C { def f: Int = 42 }")
    val m = getAsmMethod(c, "f")
    val opCodes = m.instructions.iterator.asScala.map(_.getOpcode).toList
    assertTrue(opCodes.contains(Opcodes.ATHROW))
    assertTrue(opCodes.contains(Opcodes.NEW))
  }

  @Test def outlineClassHasScalaSignature(): Unit = {
    val c = compileClass("class C { def f: Int = 1 }")
    val annots = Option(c.visibleAnnotations).map(_.asScala.toList).getOrElse(Nil)
    assertTrue(
      annots.exists(_.desc == "Lscala/reflect/ScalaSignature;") ||
        annots.exists(_.desc == "Lscala/reflect/ScalaLongSignature;"))
  }

  @Test def outlineOmitsDefaultGetter(): Unit = {
    val c = compileClass("class C { def f(x: Int = 1): Int = x }")
    val names = c.methods.iterator.asScala.map(_.name).toSet
    assertFalse(names.exists(_.contains("$default$")))
  }

  @Test def outlineSeparateCompilationSmoke(): Unit = {
    val cs = compileClassesSeparately(
      List(
        "package p; class A { def f: Int = 1 }",
        "package p; class B { def g(a: p.A) = a.f }"
      ),
      extraArgs = "-Youtline -usejavacp"
    )
    val b = findClass(cs, "p/B")
    assertNotNull(getAsmMethod(b, "g"))
  }
}
