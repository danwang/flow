//flowlint sketchy-boolean-op:error
var x = false;
var y: () => void = () => {};

// Error: y() is unreachable
x && y();
