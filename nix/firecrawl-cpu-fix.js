// gVisor (runsc) does not expose usable CPU metrics: systeminformation's
// currentLoad() returns NaN and /proc/stat reads as all-zeros. Firecrawl's
// SystemMonitor caches that NaN, so acceptConnection() (`NaN < MAX_CPU`) is
// always false and the worker refuses every job, spin-logging
// "WORKER STALLED / Can't accept connection due to RAM/CPU load" ~1/s.
//
// Preloaded via NODE_OPTIONS=--require so it runs before the app and shares
// the same module cache. We patch systeminformation.currentLoad() in place so
// it never yields NaN: derive a real figure from the container's cgroup-v1
// cpuacct.usage (which gVisor *does* expose), falling back to 0 (idle) so the
// worker always accepts work. SystemMonitor divides currentLoad by 100, so we
// return a percentage.
const fs = require("fs");
const os = require("os");
const si = require("/app/node_modules/systeminformation");

let prevUsageNs = null;
let prevTime = Date.now();

function cgroupV1CpuPercent() {
  try {
    const usageNs = parseInt(
      fs.readFileSync("/sys/fs/cgroup/cpuacct/cpuacct.usage", "utf8").trim(),
      10,
    );
    const now = Date.now();
    const numCPUs = os.cpus().length || 1;
    if (prevUsageNs === null) {
      prevUsageNs = usageNs;
      prevTime = now;
      return 0;
    }
    const deltaNs = usageNs - prevUsageNs;
    const deltaTimeNs = (now - prevTime) * 1e6; // ms -> ns
    prevUsageNs = usageNs;
    prevTime = now;
    if (deltaTimeNs <= 0) return 0;
    const frac = deltaNs / deltaTimeNs / numCPUs;
    return Number.isFinite(frac) && frac >= 0 ? frac * 100 : 0;
  } catch (e) {
    return 0;
  }
}

const origCurrentLoad = si.currentLoad.bind(si);
si.currentLoad = async function () {
  let d;
  try {
    d = await origCurrentLoad();
  } catch (e) {
    d = {};
  }
  if (!d || !Number.isFinite(d.currentLoad)) {
    return Object.assign({}, d, { currentLoad: cgroupV1CpuPercent() });
  }
  return d;
};
