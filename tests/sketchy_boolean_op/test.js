//flowlint sketchy-boolean-op:error
var foo = () => {};

// Error: foo() is unreachable
var a: false = false;
a && foo();

// Error: foo() is unreachable
var b = null;
b && foo();

// No error
var c: ?Object = {};
c && foo();

// No error
var d: number = 3;
d && foo();

// Error: left value is never used
var e = {};
e && foo();

// Error: left value is never used
var f = () => {};
f && foo();
