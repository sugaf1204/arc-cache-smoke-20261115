import fs from 'node:fs';
import pc from 'picocolors';
fs.mkdirSync('dist',{recursive:true});
fs.writeFileSync('dist/result.txt',pc.stripColor ? pc.stripColor(fs.readFileSync('src/message.txt','utf8')) : fs.readFileSync('src/message.txt','utf8'));
