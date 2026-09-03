var out = (typeof print === "function") ? print : console.log;
var now = Date.now;
// A: the prior report's shape — the loop at global/eval scope, `let` in a block
var t = now();
{ let x = 0; for (let i = 0; i < 50000000; i++) x = (x + i * 3) | 0; }
out("global-block-let\t" + (now() - t) + " ms");
// B: the same loop inside a function
function inFn() { var x = 0; for (var i = 0; i < 50000000; i++) x = (x + i * 3) | 0; return x; }
t = now(); inFn(); out("in-function-var \t" + (now() - t) + " ms");
// C: function but with let (to separate 'function' from 'var')
function inFnLet() { let x = 0; for (let i = 0; i < 50000000; i++) x = (x + i * 3) | 0; return x; }
t = now(); inFnLet(); out("in-function-let \t" + (now() - t) + " ms");
