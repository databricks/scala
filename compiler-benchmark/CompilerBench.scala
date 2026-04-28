// Compile-self benchmark driver. Runs multiple times in one JVM for warmup.
package benchmark

import java.io.{File, PrintWriter, StringWriter}
import java.nio.file.{Files, Path, Paths}
import scala.tools.nsc.{CompilerCommand, Global, Settings}
import scala.tools.nsc.reporters.ConsoleReporter

/** Optional bridge to `perf stat --control fifo:ctl,ack`.  When the env
 *  vars BENCH_CTL_FIFO + BENCH_ACK_FIFO are set, we tell perf to start
 *  / stop counting around each measurement iteration so the totals
 *  reflect ONLY steady-state work, not warmup or JVM startup.
 *  Whole-JVM `perf stat` totals were dominated by warmup-iteration JIT
 *  on some optimization commits, breaking the wall-vs-counter signal.
 */
final class PerfControl private (
    out: java.io.OutputStream,
    in:  java.io.BufferedReader) {
  private def cmd(s: String): Unit = {
    out.write((s + "\n").getBytes())
    out.flush()
    // perf may emit a leading space; trim before checking
    val ack = Option(in.readLine()).map(_.trim).orNull
    if (ack == null || !ack.startsWith("ack"))
      throw new RuntimeException(
        s"perf control: expected 'ack', got '$ack' (after '$s')")
  }
  def enable():  Unit = cmd("enable")
  def disable(): Unit = cmd("disable")
  def close():   Unit = { out.close(); in.close() }
}

object PerfControl {
  def fromEnv(): Option[PerfControl] = {
    val c = System.getenv("BENCH_CTL_FIFO")
    val a = System.getenv("BENCH_ACK_FIFO")
    if (c == null || a == null || c.isEmpty || a.isEmpty) None
    else {
      // Order matters: perf opens ctl first (read) then ack (write).
      // We mirror that: open ctl for write first, then ack for read.
      val out = new java.io.FileOutputStream(c)
      val in  = new java.io.BufferedReader(
        new java.io.InputStreamReader(new java.io.FileInputStream(a)))
      Some(new PerfControl(out, in))
    }
  }
}

object CompilerBench {
  def fileExists(p: String) = new File(p).exists()

  def listSrcs(dir: String, excludes: Set[String] = Set.empty): List[String] = {
    import java.nio.file.{Files => JFiles}
    import scala.collection.JavaConverters._
    val root = Paths.get(dir)
    val it = JFiles.walk(root).iterator().asScala
    val result = it.filter(p => !JFiles.isDirectory(p))
      .map(_.toString)
      .filter(p => (p.endsWith(".scala") || p.endsWith(".java")) && !excludes.exists(p.endsWith(_)))
      .toList
    result
  }

  def runCompile(srcs: List[String], cp: String, outDir: String, extraOpts: List[String] = Nil): Long = {
    val settings = new Settings(err => throw new RuntimeException(err))
    settings.classpath.value = cp
    settings.outdir.value = outDir
    settings.nowarn.value = true
    settings.usejavacp.value = false
    for (o <- extraOpts) {
      val consumed = settings.processArgumentString(o)
      if (!consumed._1) throw new RuntimeException(s"Failed to process: $o")
    }
    val reporter = new ConsoleReporter(settings)
    val global = new Global(settings, reporter)
    val start = System.nanoTime()
    val run = new global.Run()
    run.compile(srcs)
    if (reporter.hasErrors) throw new RuntimeException("Compile errors")
    val elapsed = System.nanoTime() - start
    global.close()
    elapsed
  }

  def main(args: Array[String]): Unit = {
    val srcDirOrFileList = args(0)
    val cp = args(1)
    val outDir = args(2)
    val warmup = if (args.length > 3) args(3).toInt else 2
    val iters = if (args.length > 4) args(4).toInt else 5

    val srcs =
      if (srcDirOrFileList.endsWith(".txt")) {
        val lines = Files.readAllLines(Paths.get(srcDirOrFileList))
        import scala.collection.JavaConverters._
        lines.asScala.toList
      } else {
        val excl = Set("BoxesRunTime.java", "ScalaRunTime.scala")
        listSrcs(srcDirOrFileList, excl)
      }

    System.err.println(s"Benchmarking ${srcs.size} source files, $warmup warmup + $iters measurement iterations")

    Files.createDirectories(Paths.get(outDir))

    val perf = PerfControl.fromEnv()
    perf.foreach(_ => System.err.println("[CompilerBench] perf control bridge active"))

    val times = new scala.collection.mutable.ArrayBuffer[Long]()
    val warmupTimes = new scala.collection.mutable.ArrayBuffer[Long]()
    for (i <- 0 until warmup + iters) {
      // cleanup output between runs
      val od = new File(outDir)
      def rm(f: File): Unit = {
        if (f.isDirectory) f.listFiles().foreach(rm)
        f.delete()
      }
      if (od.isDirectory) od.listFiles().foreach(rm)
      val measured = i >= warmup
      if (measured) perf.foreach(_.enable())
      val t = runCompile(srcs, cp, outDir)
      if (measured) perf.foreach(_.disable())
      val ms = t / 1000000L
      val kind = if (measured) "measured" else "warmup"
      System.err.println(f"iter $i%2d ($kind%8s): $ms%6d ms")
      if (measured) times += t else warmupTimes += t
    }
    perf.foreach(_.close())

    val sorted = times.sorted
    val median = sorted(sorted.size / 2)
    val avg = times.sum / times.size
    val min = times.min
    val max = times.max
    val warmSum = warmupTimes.sum
    val measSum = times.sum
    def ms(l: Long) = l / 1000000L
    System.err.println(f"min=${ms(min)}%d ms median=${ms(median)}%d ms avg=${ms(avg)}%d ms max=${ms(max)}%d ms")
    System.err.println(f"warm_total=${ms(warmSum)}%d ms measured_total=${ms(measSum)}%d ms")
    // stdout: <median_ms>\t<measured_total_ms>\t<warmup_total_ms>\t<n_warmup>\t<n_iters>
    // (run-bench.sh callers that just want the median can still use `... | tail -1 | awk '{print $1}'`)
    println(f"${ms(median)}\t${ms(measSum)}\t${ms(warmSum)}\t$warmup\t$iters")
  }
}
