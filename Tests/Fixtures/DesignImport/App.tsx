import React from 'react';
export default function Welcome() {
  return <main style={{margin:40,width:420,boxSizing:"border-box",padding:32,background:'#fff',borderRadius:16}}>
    <h1 style={{fontSize:28,lineHeight:'36px',margin:'0 0 16px'}}>Release checklist</h1>
    <p style={{fontSize:16,lineHeight:'24px',margin:'0 0 24px'}}>3 checks passed · 1 pending</p>
    <button style={{width:356,height:48,border:0,borderRadius:12,background:'#6254d9',color:'#fff',fontSize:16,fontWeight:600}}>Open release</button>
  </main>;
}
