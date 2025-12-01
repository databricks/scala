package scala.tools.nsc.interactive

import org.junit.Test

import scala.reflect.internal.util.BatchSourceFile
import scala.tools.nsc.interactive.tests.InteractiveTest

class PresentationCompilerTest {
  @Test def run13112(): Unit = {
    t13112.main(null)
  }
}

object t13112 extends InteractiveTest {
  val code =
    """case class Foo(name: String = "")
      |object Foo extends Foo("")
      |""".stripMargin

  override def execute(): Unit = {
    val source = new BatchSourceFile("Foo.scala", code)

    val res = new Response[Unit]
    compiler.askReload(List(source), res)
    res.get
    askLoadedTyped(source).get

    // the second round was failing (see scala/bug#13112 for details)
    compiler.askReload(List(source), res)
    res.get
    val reloadRes = askLoadedTyped(source).get
    assert(reloadRes.isLeft)
  }
}
