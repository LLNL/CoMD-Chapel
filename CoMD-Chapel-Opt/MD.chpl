use types;
use configs;
use setup;
use helpers;
use force;
use forcelj;
use forceeam;
use BlockDist;
use Time;
use VisualDebug;
use rand;

var vSim  : Validate;
var f : Force;

proc initGrid(latticeConstant: real, const ref force: Force) {
  simLow  = (0.0,0.0,0.0);
  const simSize = (nx:real, ny:real, nz:real) * latticeConstant;
  simHigh = simSize;

  const minSimSize = 2*force.cutoff;
  assert(simSize(1) >= minSimSize && simSize(2) >= minSimSize && simSize(3) >= minSimSize);
  assert(force.latticeType == "FCC" || force.latticeType == "fcc");

  for i in 1..3 do numBoxes(i) = (simSize(i)/force.cutoff) : int;

  // assert(numBoxes(1) >= xproc && numBoxes(2) >= yproc && numBoxes(3) >= zproc);

  boxSize = simSize / numBoxes;

  const targetLocales : [locDom] locale;
  var count: int(32) = 0;
  for l in targetLocales {
    l = Locales(count);
    count = count + 1;
  }

  const boxSpace = {1..numBoxes(1), 1..numBoxes(2), 1..numBoxes(3)};
  const distSpace = boxSpace dmapped Block(boundingBox=boxSpace, targetLocales=targetLocales);
  // assert(locDom == distSpace._value.dist.targetLocDom);

  locGrid = distSpace._value.dist.targetLocales;
  // assert(locGrid == targetLocales);

  coforall ijk in locDom {
    on locGrid[ijk] {
      // grab our chunk of the real domain
      const MyLocDom = distSpace._value.locDoms[ijk].myBlock;

      const high = MyLocDom.high;
      const low  = MyLocDom.low - 1;
      const domHigh = (high(1):real, high(2):real, high(3):real) * boxSize;
      const domLow  = (low(1):real, low(2):real, low(3):real) * boxSize;
      const domSize = domHigh - domLow;

      const invBoxSize = (1/boxSize(1), 1/boxSize(2), 1/boxSize(3));
      var MyDom = new Domain(localDom=MyLocDom,
                         invBoxSize=invBoxSize, boxSpace=boxSpace, numBoxes=numBoxes,
                         domHigh=domHigh, domLow=domLow,
                         force=if(replicateForce) then force.replicate() else force);

      Grid[ijk] = MyDom;

      const lDh = locDom.high;
      const bSh = boxSpace.high;
      const sS  = simSize;

local {
      // alias to save typing
      const halo => MyDom.halo;
      var destSlice => MyDom.destSlice;
      var srcSlice => MyDom.srcSlice;
      var neighs => MyDom.neighs;
      const neighDom => MyDom.neighDom;
      var bRecv => MyDom.bRecv;
      var bSend => MyDom.bSend;
      var pbc => MyDom.pbc;
 
      var neighOff : [neighDom] int3;
      neighOff[1] = (-1,0,0);
      neighOff[2] = (1,0,0);
      neighOff[3] = (0,-1,0);
      neighOff[4] = (0,1,0);
      neighOff[5] = (0,0,-1);
      neighOff[6] = (0,0,1);

      for (dest, src, recv, send, shift, neigh, nOff) in zip(destSlice, srcSlice, bRecv, bSend, pbc, neighs, neighOff) {
        dest = halo.interior(2*nOff);
        const bC = dest.size;
        src = dest;
        var neighbor = ijk + nOff;
        var srcOff = (0,0,0);
        recv = new FaceArr(d=bC);
        send = new FaceArr(d=bC);
        for i in 1..3 {
          if(neighbor(i) < 0) {
            neighbor(i) = lDh(i);
            srcOff(i) = bSh(i);
            shift(i) = -1.0*sS(i);
          }
          else if(neighbor(i) > lDh(i)) {
            neighbor(i) = 0;
            srcOff(i) = -bSh(i);
            shift(i) = 1.0*sS(i);
          }
        }
        src = src.translate(srcOff);
        neigh = neighbor;
      }
}
    } // end of on statement
  } // end of for statement
}


/// Computes the center of mass velocity of the system.
proc computeVcm() {
tArray[timerEnum.COMMREDUCE].start();
  coforall ijk in locDom {
    on locGrid[ijk] {
      var vcmTemp = (0.0, 0.0, 0.0);
      const MyDom = Grid[ijk];
local {
      forall box in MyDom.cells[MyDom.localDom] with (+ reduce vcmTemp) {
        for i in 1..box(1) {
          const ref atom = box(2)[i];
          vcmTemp += atom.v;
        }
      }
      MyDom.vcmTemp = vcmTemp;
}
    }
  }
  var vcm = (0.0, 0.0, 0.0);
  forall ijk in locDom with (+ reduce vcm) {
      vcm += Grid[ijk].vcmTemp;
  }
tArray[timerEnum.COMMREDUCE].stop();
  return vcm/numAtoms;
}

proc setVcm(newVcm : real3) {
  var oldVcm = computeVcm();
  var vShift = newVcm - oldVcm;

  coforall ijk in locDom {
    on locGrid[ijk] {
      const MyDom = Grid[ijk];
local {
      forall box in MyDom.cells[MyDom.localDom] {
        for i in 1..box(1) {
          ref atom = box(2)[i];
          atom.v += vShift;
        }
      }
}
    }
  }
}

proc totalEnergy() {
tArray[timerEnum.COMMREDUCE].start();
if useChplVis then tagVdebug("totalEnergy");
  coforall ijk in locDom {
    on locGrid[ijk] {
      const MyDom = Grid[ijk];
local {
      var keTemp = 0.0;
      var peTemp = 0.0;
      forall (box, pe) in zip(MyDom.cells[MyDom.localDom], MyDom.pe) with (+ reduce keTemp, + reduce peTemp) {
        for i in 1..box(1) {
          const ref atom = box(2)[i];
          keTemp += 0.5 * atom.mass * dot(atom.v, atom.v);
          peTemp += pe[i];
        }
      }
      MyDom.domKEPE = (keTemp, peTemp);
}
    }
  }
  keTotal = 0.0;
  peTotal = 0.0;
  forall ijk in locDom with (+ reduce keTotal, + reduce peTotal) {
    const e = Grid[ijk].domKEPE;
    keTotal += e(1);
    peTotal += e(2);
  }
if useChplVis then pauseVdebug();
tArray[timerEnum.COMMREDUCE].stop();
}

proc setTemperature(const in temp : real) : void {
  coforall ijk in locDom {
    on locGrid[ijk] {
      const MyDom = Grid[ijk];
local {
      forall box in MyDom.cells[MyDom.localDom] {
        for i in 1..box(1) {
          ref atom = box(2)[i];
		  var sigma : real = sqrt(kB_eV * temp/atom.mass);
		  var seed : uint(64) = mkSeed((atom.gid-1) : uint(32), 123);
		  atom.v = (sigma * gasdev(seed), sigma * gasdev(seed), sigma * gasdev(seed));
        }
      }
}
    }
  }

  // compute the resulting temperature
  // kinetic energy  = 3/2 kB * Temperature 
  if (temp == 0.0) then return;
  var vZero = (0.0, 0.0, 0.0);
  setVcm(vZero);

  totalEnergy();
  var tempT : real = ((keTotal/numAtoms)/kB_eV)/1.5;
  // scale the velocities to achieve the target temperature
  var scaleFactor = sqrt(temp/tempT);

  coforall ijk in locDom {
    on locGrid[ijk] {
      const MyDom = Grid[ijk];
local {
      forall box in MyDom.cells[MyDom.localDom] {
        for i in 1..box(1) {
          ref atom = box(2)[i];
		  atom.v *= scaleFactor;
        }
      }
}
    }
  }

  totalEnergy();
  tempT = (keTotal/numAtoms)/kB_eV/1.5; // why??
}

proc randomDisplacements(temp : real) : void {
  coforall ijk in locDom {
    on locGrid[ijk] {
      const MyDom = Grid[ijk];
local {
      forall box in MyDom.cells[MyDom.localDom] {
        for i in 1..box(1) {
          ref atom = box(2)[i];
          var seed : uint(64) = mkSeed((atom.gid-1) : uint(32), 457);
          atom.r += (2.0*lcg61(seed)-1.0) * delta;
        }
      }
}
    }
  }
}

proc sortAtomsInCells() {
tArray[timerEnum.SORT].start();
//  if(doeam) then {
    coforall ijk in locDom {
      on locGrid[ijk] {
        const MyDom = Grid[ijk];
local {
        forall box in MyDom.cells {
          //QuickSort(box.atoms[1..box.count]);
          //InsertionSort(box.atoms[1..box.count]);
          //BubbleSort(box.atoms[1..box.count]);
///*
          for i in 2..box(1) {
            const x = box(2)[i];
            var j = i-1;
            while (j >= 1 && box(2)[j] > x) {
              box(2)[j+1] <=> box(2)[j];
              j -= 1;
            }
            box(2)[j+1] = x;
          }
//*/
        }
}
      }
    }
//  }
tArray[timerEnum.SORT].stop();
}

proc updateLinkCells() {
  coforall ijk in locDom {
    on locGrid[ijk] {
      const MyDom = Grid[ijk];
local {
      // alias to save typing
      const halo => MyDom.halo;
      const neighDom = MyDom.neighDom;
      const invBoxSize = MyDom.invBoxSize;
 
      var neighOff : [neighDom] int3;
      neighOff[1] = (-1,0,0);
      neighOff[2] = (1,0,0);
      neighOff[3] = (0,-1,0);
      neighOff[4] = (0,1,0);
      neighOff[5] = (0,0,-1);
      neighOff[6] = (0,0,1);

      // empty halo cells
      for nOff in neighOff {
        var h = halo.interior(1*nOff);
        forall box in MyDom.cells[h] do box(1) = 0;
      }

      // move atoms locally
      for (box, boxIdx) in zip(MyDom.cells[MyDom.localDom], MyDom.localDom) {
      //for (box, boxIdx) in zip(MyDom.locCells, MyDom.localDom) {
        var ii : int(32) = 1;
        while (ii <= box(1)) {
          var pos = box(2)[ii].r;
          var dBoxIdx : int3 = getBoxFromCoords(pos, invBoxSize);

          // if another box
          if(boxIdx != dBoxIdx) then {
            // check if dest box is valid and has space for another atom
            // assert(halo.member(dBoxIdx));
            // assert(MyDom.cells[dBoxIdx].count < MAXATOMS);

            // add to new box
            MyDom.cells[dBoxIdx](1) += 1;
            MyDom.cells[dBoxIdx](2)[MyDom.cells[dBoxIdx](1)] = box(2)[ii];

            // remove from old box (copy the last atom in old box to ii)
            const oldCount = box(1);
            box(1) -= 1;
            if(box(1)) then 
              box(2)[ii] = box(2)[oldCount];

            // decrement number of atoms if dest box not local
            if(!MyDom.localDom.member(dBoxIdx)) then MyDom.numLocalAtoms -= 1; 
          }
          else ii += 1;
        }
      }
}
    }
  }
}

inline proc gatherAtoms(const ref MyDom:Domain, const in face : int) : int(32) {
local {
    const dest => MyDom.destSlice; 
    var numLocalAtoms : int(32) = 0;

    // wait for the neighbor to finish its read
    if(face % 2) then MyDom.nM$; else MyDom.nP$;
    var faceArr => MyDom.bRecv[face].a;
    var faceCount = MyDom.bRecv[face].count;

    const invBoxSize = MyDom.invBoxSize;
    const pbc = MyDom.pbc[face];

    for atom in faceArr[1..faceCount] {
      const box : int3 = getBoxFromCoords(atom.r+pbc, invBoxSize);
      ref dBox = MyDom.cells[box];
      dBox(1) += 1;
      const count = dBox(1);
      dBox(2)[count] = atom;
      dBox(2)[count].r += pbc;
      if(MyDom.localDom.member(box)) then numLocalAtoms += 1; 
    }
    return numLocalAtoms;
}
}

inline proc haloExchange(const ref MyDom : Domain, const in face:int) {
  const src = MyDom.srcSlice[face];
  const neighs => MyDom.neighs;
  var faceArr => MyDom.bRecv[face].a;
  ref faceCount = MyDom.bRecv[face].count;
  const nf = neighs[face];
/* 
  const dLocale = here.id;
  const dLen    = faceArr.domain.numIndices.safeCast(size_t);
  const dIndex  = faceArr._value.getDataIndex(faceArr.domain.low);
  const dArr    = faceArr._value.theData;
  const dData   = _ddata_shift(faceArr._value.eltType, dArr, dIndex);
*/
  on locGrid[nf] {
    const g = Grid[nf];
    const sf = src;
    var gFaceArr => g.bSend[face].a;
    var gFaceCount = 0;
local {
    for box in g.cells[sf] {
      for i in 1..box(1) {
        gFaceCount += 1;
        ref a = box(2)(i);
        gFaceArr[gFaceCount] = a;
      }
    }
}
    faceCount = gFaceCount;
    faceArr[1..gFaceCount] = gFaceArr[1..gFaceCount];
/* 
    const sArr = gFaceArr._value.theData;
    const sIndex  = gFaceArr._value.getDataIndex(gFaceArr.domain.low);
    const sData = _ddata_shift(gFaceArr._value.eltType, sArr, sIndex);
    __primitive("chpl_comm_array_put", sData[0], dLocale, dData[0], dLen); 
*/ 

local {
      // indicate to the neighbor that read is done
      if(face % 2) then g.nP$.writeXF(true); else g.nM$.writeXF(true);
}
  }
}

// if only one cells in this dimension, then read in parallel
// but add atoms serially
inline proc exchangeData(const ref MyDom:Domain, const in i : int) {
  var nAtoms : int(32) = 0;
  cobegin {
    { haloExchange(MyDom, i); }
    { haloExchange(MyDom, i+1); }
  }
  nAtoms += gatherAtoms(MyDom, i);
  nAtoms += gatherAtoms(MyDom, i+1);
  MyDom.numLocalAtoms += nAtoms;
}

// if 2 or more cells in this dimension, then read 
// and add atoms in parallel
inline proc exchangeData(const ref MyDom:Domain, const in i : int) 
            where MyDom.localDom.dim((i/2):int+1).size > 1 {
  var nAtomsM : int(32) = 0;
  var nAtomsP : int(32) = 0;
  cobegin with (ref nAtomsM, ref nAtomsP) {
    { haloExchange(MyDom, i); nAtomsM = gatherAtoms(MyDom, i); }
    { haloExchange(MyDom, i+1); nAtomsP = gatherAtoms(MyDom, i+1); }
  }
  MyDom.numLocalAtoms += (nAtomsM + nAtomsP);
}

proc redistributeAtoms() {
tArray[timerEnum.REDIST].start();
if useChplVis then tagVdebug("updateLinkCells");
  updateLinkCells();
if useChplVis then pauseVdebug();
if useChplVis then tagVdebug("haloExchange");
tArray[timerEnum.ATOMHALO].start();
  // halo exchange
  for i in 1..6 by 2 {
    coforall ijk in locDom {
      on locGrid[ijk] {
        exchangeData(Grid[ijk], i);
      }
    }
  }
tArray[timerEnum.ATOMHALO].stop();
if useChplVis then pauseVdebug();

if useChplVis then tagVdebug("sortAtoms");
  sortAtomsInCells();
if useChplVis then pauseVdebug();

tArray[timerEnum.REDIST].stop();
}

proc computeForce() {
tArray[timerEnum.FORCE].start();
  if(replicateForce) then f.computeLocal(); else f.compute();
tArray[timerEnum.FORCE].stop();
}

proc initSimulation() {
tArray[timerEnum.FCREATE].start();
  if(doeam) {
    f = new ForceEAM(potDir, potName, potType);
  }
  else {
    f = new ForceLJ();
  }
tArray[timerEnum.FCREATE].stop();

  f.print();

  writeln(); 

  var latticeConstant : real = lat;
  if(lat < 0.0) then latticeConstant = f.lat;

tArray[timerEnum.INITGRID].start();
if useChplVis then tagVdebug("initGrid");
  initGrid(latticeConstant, f);
if useChplVis then pauseVdebug();
tArray[timerEnum.INITGRID].stop();

tArray[timerEnum.EPILOGUE].start();
  f.epilogue();
tArray[timerEnum.EPILOGUE].stop();

if useChplVis then tagVdebug("createLattice");
  createFccLattice(latticeConstant);
if useChplVis then pauseVdebug();

  const cutoff = f.cutoff;

  // delete original force object since it has been replicated on all domains
  // if(replicateForce) then delete force;

if useChplVis then tagVdebug("setTemp");
  setTemperature(temp);
//if useChplVis then pauseVdebug();
if useChplVis then tagVdebug("randomDisp");
  randomDisplacements(temp);
if useChplVis then pauseVdebug();
tArray[timerEnum.REDIST1].start();
  redistributeAtoms();
tArray[timerEnum.REDIST1].stop();
tArray[timerEnum.F1].start();
  computeForce();
tArray[timerEnum.F1].stop();
  totalEnergy();

  // const maxOcc = maxOccupancy();
  vSim.eInit = keTotal + peTotal;

  writeln("Simulation data:");
  writeln("   Total atoms        : ",   numAtoms);
  writef("   Min global bounds  : [%14.10dr, %14.10dr, %14.10dr ]\n", simLow(1), simLow(2), simLow(3));
  writef("   Max global bounds  : [%14.10dr, %14.10dr, %14.10dr ]\n", simHigh(1), simHigh(2), simHigh(3));

  writeln();
  writeln("Decomposition Data:");
  writef("   Locales            : %6i, %6i, %6i = %6i\n", xproc, yproc, zproc, numLocales);
  writef("   Total boxes        : %6i, %6i, %6i = %6i\n", numBoxes(1), numBoxes(2), numBoxes(3), numBoxes(1)*numBoxes(2)*numBoxes(3));
  writef("   Box size           : [%14.10dr, %14.10dr, %14.10dr ]\n", boxSize(1), boxSize(2), boxSize(3));
  writef("   Box factor         : [%14.10dr, %14.10dr, %14.10dr ]\n", boxSize(1)/cutoff, boxSize(2)/cutoff, boxSize(3)/cutoff);
  // writeln("   Max Link Cell Occupancy: ", maxOcc, " of ", MAXATOMS);

  writeln(); 

  writef("Initial energy : %14.12dr, atom count : %i \n", vSim.eInit/vSim.nAtomsInit, vSim.nAtomsInit);

  writeln(); 

  var yyyymmdd = getCurrentDate();
  writeln(yyyymmdd(1), "-", yyyymmdd(2), "-", yyyymmdd(3), ", ", getCurrentTime(TimeUnits.hours), " Initialization Finished");
}

inline proc getBoxFromCoords(const in r : real3, const in invBoxSize: real3) {
  var boxCoords : int3;
  const temp = r * invBoxSize + (1,1,1);

  // can't cast from 3*real to 3*int (yet?)
  for i in 1..3 do 
    boxCoords(i) = temp(i) : int;

  return boxCoords;
  
}

proc createFccLattice(lat : real) : void {
  coforall ijk in locDom {
    on locGrid[ijk] {
      const MyDom = Grid[ijk];
      const force = MyDom.force;
      const name : string   = force.name;
      const mass : real = force.mass;
      const atomicNumber : int  = force.atomicNumber;
local {
      const basis : [1..nb] real3 = ( (0.25, 0.25, 0.25),
                                     (0.25, 0.75, 0.75),
                                     (0.75, 0.25, 0.75),
                                     (0.75, 0.75, 0.25) );

      const domLow = MyDom.domLow;
      const domHigh = MyDom.domHigh;
      const invBoxSize = MyDom.invBoxSize;
      var start, end : (int(32), int(32), int(32));
      for i in 1..3 {
        start(i) = floor(domLow(i)/lat) : int(32);
        end(i)   = ceil(domHigh(i)/lat) : int(32);
      }
	  for ix in start(1)..end(1) {
	    for iy in start(2)..end(2) {
	      for iz in start(3)..end(3) {
            for ib in 1..nb {
              var rx  : real = (ix+basis(ib)(1)) * lat;
              var ry  : real = (iy+basis(ib)(2)) * lat;
              var rz  : real = (iz+basis(ib)(3)) * lat;
              var gid : int(32) = ib+nb*(iz+nz*(iy+ny*(ix))) : int(32);
              if (rx < domLow(1) || rx >= domHigh(1)) then continue;
              if (ry < domLow(2) || ry >= domHigh(2)) then continue;
              if (rz < domLow(3) || rz >= domHigh(3)) then continue;
              var r = (rx, ry, rz);
              var box : int3 = getBoxFromCoords(r, invBoxSize);

              // assert(MyDom.halo.member(box));
              // assert(MyDom.cells[box].count < MAXATOMS);

              MyDom.cells[box](1) += 1;
              MyDom.cells[box](2)[MyDom.cells[box](1)] = new Atom(gid, mass, 1 : int(32), (rx, ry, rz));
              if(MyDom.localDom.member(box)) then MyDom.numLocalAtoms += 1; 

            }
          }
        }
	  }
}
    }
  }
  sumAtoms();
  vSim.nAtomsInit = numAtoms;
  // assert(numAtoms == nx*ny*nz*nb);
}

// TODO: max reduce intent is still not available as of Chapel v1.12.
// Currently this proc is completely serial 
// Rewrite this proc using max reduce intent when available
proc maxOccupancy() {
tArray[timerEnum.COMMREDUCE].start();
  var maxOcc = 0;
  for ijk in locDom {
    on locGrid[ijk] {
      const MyDom = Grid[ijk];
      var maxOccTemp = 0;
      for box in MyDom.cells[MyDom.localDom] {
        maxOccTemp = max(maxOccTemp, box(1));
      }
      maxOcc = max(maxOccTemp, maxOcc);
    }
  }
tArray[timerEnum.COMMREDUCE].stop();
  return maxOcc;
}

proc sumAtoms() {
tArray[timerEnum.COMMREDUCE].start();
if useChplVis then tagVdebug("sumAtoms");
  numAtoms = 0;
  forall ijk in locDom with (+ reduce numAtoms) {
    numAtoms += Grid[ijk].numLocalAtoms;
  }
if useChplVis then pauseVdebug();
tArray[timerEnum.COMMREDUCE].stop();
}

proc advanceVelocity(const in dt : real) {
tArray[timerEnum.VELOCITY].start();
if useChplVis then tagVdebug("advanceVelocity");
  coforall ijk in locDom {
    on locGrid[ijk] {
      const MyDom = Grid[ijk];
local {
      forall (box, f) in zip(MyDom.cells[MyDom.localDom], MyDom.f) {
        for i in 1..box(1) {
          ref a = box(2)(i);
          a.v += ((dt/a.mass)*f(i));
        }
      }
}
    }
  }
if useChplVis then pauseVdebug();
tArray[timerEnum.VELOCITY].stop();
}

proc advancePosition(const in dt : real) {
tArray[timerEnum.POSITION].start();
if useChplVis then tagVdebug("advancePosition");
  coforall ijk in locDom {
    on locGrid[ijk] {
      const MyDom = Grid[ijk];
local {
      forall box in MyDom.cells[MyDom.localDom] {
        for i in 1..box(1) {
          ref a = box(2)(i);
          a.r += (dt*a.v);
        }
      }
}
    }
  }
if useChplVis then pauseVdebug();
tArray[timerEnum.POSITION].stop();
}

proc timestep(const in nSteps: int, const in dt : real) {
  for ii in 1..nSteps {
    advanceVelocity(0.5*dt);
    advancePosition(dt);
    redistributeAtoms();
    computeForce();
    advanceVelocity(0.5*dt);
  }
  totalEnergy();
}

proc printThings(t : int, tPrev : int, elapsed : real) {
  var temp = keTotal / (kB_eV * 1.5) / numAtoms;

  var timePerAtom = 1.0e6*elapsed/(((t-tPrev)*numAtoms) : real);

  writef(" %6i %10.2dr %18.12dr %18.12dr %18.12dr %12.4dr %10.4dr %12i\n", t, t*dt, (keTotal+peTotal)/numAtoms, peTotal/numAtoms, keTotal/numAtoms, temp, timePerAtom, numAtoms);
}

//use VisualDebug;

proc main(args: [] string) {
tArray[timerEnum.TOTAL].start();
if useChplVis then startVdebug(visName);
if useChplVis then pauseVdebug();

  for a in args {
    if(a == "--help") {
      writeln("The following command line options are supported:");
      writeln("--help           : print this message");
      writeln("--potDir         : potential directory (default pots)");
      writeln("--potName        : potential name (default Cu_u6.eam)");
      writeln("--potType        : potential type (funcfl or setfl, default funcfl)");
      writeln("--doeam          : eam potential (LJ or EAM, default LJ)");
      writeln("--nx             : num of unit cells in x (default 20)");
      writeln("--ny             : num of unit cells in y (default 20)");
      writeln("--nz             : num of unit cells in z (default 20)");
      writeln("--xproc          : num of target locales in x (default 1)");
      writeln("--yproc          : num of target locales in y (default 1)");
      writeln("--zproc          : num of target locales in z (default 1)");
      writeln("--nSteps         : total number of time steps (default 100)");
      writeln("--printRate      : print interval (in number of time steps, default 10)");
      writeln("--dt             : timestep length (in fs, default 1)");
      writeln("--lat            : lattice parameter (in Angs, default -1.0)");
      writeln("--temp           : initial temprature (in K, default 600K)");
      writeln("--delta          : initial delta (in Angs, default 0)");
      writeln("--replicateForce : replicate the force object per locale (default true, will replicate)");
      writeln("--useChplVis     : enable chplvis (default false, disabled)");
      writeln("--visName        : name of chplvis output file (default MD-Vis-0)");
      exit(0);
    }
  }

  writeln("Mini-Application Name: ", "CoMD-Chapel");
  writeln("Mini-Application Version: ", 1.0);

  var yyyymmdd = getCurrentDate();
  writeln("Run Date/Time: ", yyyymmdd(1), "-", yyyymmdd(2), "-", yyyymmdd(3), ", ", getCurrentTime(TimeUnits.hours), "(number of hours since midnight)");

  writeln("Command Line Parameters:");
  writeln("   doeam               : ", doeam);
  writeln("   potDir              : ", potDir);
  writeln("   potName             : ", potName);
  writeln("   potType             : ", potType);
  writeln("   nx                  : ", nx);
  writeln("   ny                  : ", ny);
  writeln("   nz                  : ", nz);
  writeln("   xproc               : ", xproc);
  writeln("   yproc               : ", yproc);
  writeln("   zproc               : ", zproc);
  writeln("   Lattice constant    : ", lat ," Angstroms");
  writeln("   nSteps              : ", nSteps);
  writeln("   printRate           : ", printRate);
  writeln("   Time step           : ", dt , " fs");
  writeln("   Initial Temperature : ", temp, " K");
  writeln("   Initial Delta       : ", delta, " Angstroms");
  writeln("   Number of locales   : ", numLocales);

  writeln();

  writeln("Runtime configuration:");
  writeln("   Locales               : ", numLocales);
  writeln("   dataParTasksPerLocale : ", dataParTasksPerLocale);
  writeln("   Number of cores       : ", Locales(0).numPUs());

  writeln(); 

tArray[timerEnum.INIT].start();
  initSimulation();
tArray[timerEnum.INIT].stop();

  writeln(); 

  yyyymmdd = getCurrentDate();
  writeln(yyyymmdd(1), "-", yyyymmdd(2), "-", yyyymmdd(3), ", ", getCurrentTime(TimeUnits.hours), " Starting simulation");
  writeln(); 
  writeln("#                                                                                         Performance");
  writeln("#  Loop   Time(fs)       Total Energy   Potential Energy     Kinetic Energy  Temperature   (us/atom)     # Atoms");

  var iStep = 0 : int;
  var elapsed = 0.0;
  var iStepPrev = -1;

tArray[timerEnum.LOOP].start();
  while (iStep < nSteps) {
    sumAtoms();
    printThings(iStep, iStepPrev, elapsed);
    iStepPrev = iStep;
tArray[timerEnum.TIMESTEP].start();
    timestep(printRate, dt);
elapsed = tArray[timerEnum.TIMESTEP].stop();
    iStep += printRate;
  }
tArray[timerEnum.LOOP].stop();

  sumAtoms();
  printThings(iStep, iStepPrev, elapsed);

if useChplVis then stopVdebug();
tArray[timerEnum.TOTAL].stop();

  yyyymmdd = getCurrentDate();
  writeln(); 
  writeln(yyyymmdd(1), "-", yyyymmdd(2), "-", yyyymmdd(3), ", ", getCurrentTime(TimeUnits.hours), " Ending simulation");
  writeln(); 

  const eInitial = vSim.eInit/vSim.nAtomsInit;
  const eFinal = (keTotal+peTotal)/numAtoms;
  writeln("Simulation Validation:");
  writef("   Initial energy  : %14.12dr\n", eInitial);
  writef("   Final energy    : %14.12dr\n", eFinal);
  writef("   eFinal/eInitial : %2.6dr\n", eFinal/eInitial);
  const nAtomsDelta = numAtoms - vSim.nAtomsInit;
  if(nAtomsDelta == 0) then {
    writeln("   Final atom count : ", numAtoms, ", no atoms lost");
  }
  else {
    writeln("#############################");
    writeln("# WARNING: ", nAtomsDelta, " atoms lost #");
    writeln("#############################");
  }
  

  writeln();
  writeln("Timings");

  writeln("        Timer        # Calls    Avg/Call (s)   Total (s)    % Loop");
  writeln("_____________________________________________________________________");

  var loopTime : real = tArray(timerEnum.LOOP).duration;
  for i in 1..timerEnum.ATOMHALO do if(tArray(i).times > 0) then tArray(i).print(loopTime);
  for i in timerEnum.SORT..timers do if(tArray(i).times > 0) then tArray(i).print(loopTime);
  writeln(); 
  yyyymmdd = getCurrentDate();
  writeln(yyyymmdd(1), "-", yyyymmdd(2), "-", yyyymmdd(3), ", ", getCurrentTime(TimeUnits.hours), " CoMD Ending");
}
