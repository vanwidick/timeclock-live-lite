const {tcMerge3}=require('../src/merge.js');const V=require('./vectors.json');let ok=true;
for(const v of V){const got=tcMerge3(v.base,v.a,v.b),sym=tcMerge3(v.base,v.b,v.a);const p=JSON.stringify(got)===JSON.stringify(v.want);
 const ps=JSON.stringify(Object.fromEntries(Object.entries(sym).map(([k,l])=>[k,[...l].sort((x,y)=>x[1]-y[1])])))===JSON.stringify(Object.fromEntries(Object.entries(v.want).map(([k,l])=>[k,[...l].sort((x,y)=>x[1]-y[1])])));
 console.log((p?'PASS ':'FAIL ')+'js '+v.name+(p?'':' got '+JSON.stringify(got)));ok=ok&&p;}
process.exit(ok?0:1);
