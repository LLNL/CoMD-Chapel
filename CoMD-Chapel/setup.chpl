// All simulation properties and definitions should go here

use types;
use configs;
use helpers;
use force;

// Defines the problem space
var simLow    : real3; // simulation lower bound
var simHigh   : real3; // simulation upper bound
var boxSize   : real3; // size of link cell
var numBoxes  : int3;  // number of link cells

// atom
///*
record Atom {
  var gid  : int(32);
  var mass : real;
  var species : int(32);
  var name : string;
  var r : real3;
  var v : real3;
}
//*/

//type Atom = (int(32), real, int(32), string, real3, real3);

inline proc >(const ref a : Atom, const ref b : Atom) : bool {
  return a.gid > b.gid;
}

inline proc <(const ref a : Atom, const ref b : Atom) : bool {
  return a.gid < b.gid;
}

inline proc <=(const ref a : Atom, const ref b : Atom) : bool {
  return !(a > b);
}

inline proc >=(const ref a : Atom, const ref b : Atom) : bool {
  return !(a < b);
}

//type AtomList = MAXATOMS*Atom;
//type FList = MAXATOMS*real3;
//type PList = MAXATOMS*real;

// link cell
///*
record Box {
  var count : int(32);
  var atoms : [1..MAXATOMS] Atom;
}
//*/

//type Box = (int(32), AtomList);

class FaceArr {
  var d : domain(3);
  var a : [d] Box;
}

// locale's domain of link cells
class Domain {
  var localDom       : domain(3);                          // local domain
  var halo           = localDom.expand(1);                 // expanded domain (local+halo)
  var cells          : [halo] Box;                         // cells in the expanded domain
  var f              : [localDom][1..MAXATOMS] real3;      // force per atom in local cells
  var pe             : [localDom][1..MAXATOMS] real;       // potential energy per atom in local cells
  var neighDom       : domain(1) = {1..6};                 // domain of neighbors on each face (xm, xp, ym, yp, zm, zp)
  var nM$, nP$       : sync bool;                          // sync updates to neighbors for each face pair (xm/xp, ym/yp, zm/zp)
  var neighs         : [neighDom] int3;                    // neighbors on each face (xm, xp, ym, yp, zm, zp)
  var temps1         : [neighDom] FaceArr;                 // temp arrays for each face (xm, xp, ym, yp, zm, zp)
  var temps2         : [neighDom] FaceArr;                 // temp arrays for each face (xm, xp, ym, yp, zm, zp)
  var srcSlice       : [neighDom] domain(3);               // src (remote) slice for each face (xm, xp, ym, yp, zm, zp)
  var destSlice      : [neighDom] domain(3);               // dest (local) slice for each face (xm, xp, ym, yp, zm, zp)
  var pbc            : [neighDom] real3;                   // periodic boundary shift for each face (xm, xp, ym, yp, zm, zp)

  var numLocalAtoms  : int(32);                            // number of atoms on this domain
  var invBoxSize     : real3;                              // 1/size of a single box
  var boxSpace       : domain(3);                          // dimensions of the simulation
  var numBoxes       : int3;                               // number of boxes in the simulation

  var domLow         : real3;                              // lower bound of this domain
  var domHigh        : real3;                              // higher bound of this domain

// The following 2 lines exist due to an issue with using reduce intents across locales
  var domKEPE        : (real, real);                       // total KE, PE for this domain
  var vcmTemp        : real3;                              // temp vcm for this domain

  var force          : Force;                              // clones! may the force be with you
//  var haloTicker1    = new Ticker("      commHaloPull");   // ticker for halo exchange  
//  var haloTicker2    = new Ticker("      commHaloSync");   // ticker for halo exchange  
//  var haloTicker3    = new Ticker("      commHaloUpdt");   // ticker for halo exchange  
}

const locDom  : domain(3) = {0..xproc-1, 0..yproc-1, 0..zproc-1};
var locGrid   : [locDom] locale;
var Grid      : [locDom] Domain;

record Validate {
  var eInit      : real;
  var nAtomsInit : int(32);
}

var numAtoms  : int(32) = 0; // total number of atoms
var peTotal   : real = 0.0;  // total potential energy
var keTotal   : real = 0.0;  // total kinetic energy
