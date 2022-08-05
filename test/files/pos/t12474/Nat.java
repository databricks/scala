// javaVersion: 17+

public sealed interface Nat permits Nat.Zero, Nat.Succ {
    public static final class Zero implements Nat {}
    public static final class Succ implements Nat {
        public Nat pred;
        Succ(Nat pred) {
            this.pred = pred;
        }
    }
}
