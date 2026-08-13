// Main app — design canvas. All theme decisions locked: dark / comfy / bronze.

const App = () => {
  return (
    <DesignCanvas
      title="Fetchproxies — redesign"
      subtitle="LocalRock design system. Pan with drag. Click any artboard to focus."
    >
      <DCSection id="snapshot" title="Snapshot detail" subtitle="Preview-led split">
        <DCArtboard id="v2" label="Snapshot detail" width={1240} height={1000}>
          <V2 />
        </DCArtboard>
      </DCSection>
      <DCSection id="pages" title="Other pages" subtitle="Jobs, Proxy, Logs, Help">
        <DCArtboard id="jobs"  label="Jobs · queue + filters"   width={1240} height={900}>
          <Jobs />
        </DCArtboard>
        <DCArtboard id="proxy" label="Proxy · chain status"     width={1180} height={900}>
          <Proxy />
        </DCArtboard>
        <DCArtboard id="logs"  label="Logs · live SSE stream"   width={1240} height={900}>
          <Logs />
        </DCArtboard>
        <DCArtboard id="help"  label="Help · operator reference" width={1240} height={1400}>
          <Help />
        </DCArtboard>
      </DCSection>
    </DesignCanvas>
  );
};

ReactDOM.createRoot(document.getElementById("root")).render(<App />);
