import React, {useState} from 'react';
export function App({items}) {
  const [selected, setSelected] = useState(items[0].id);
  const item = items.find(i => i.id === selected);
  return <div data-testid="layout" className="grid grid-cols-[1fr_3fr] gap-4 bg-white">
    <nav data-testid="list">{items.map(i => <button key={i.id}
      aria-pressed={i.id === selected} onClick={() => setSelected(i.id)}>{i.name}</button>)}</nav>
    <section data-testid="workspace"><h2>{item.name}</h2><p>{item.detail}</p>
      <input aria-label="Notes" /></section>
  </div>;
}
