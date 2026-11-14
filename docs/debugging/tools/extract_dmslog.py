"""Extract the bytes SignMaster sent to the cutter from a Device Monitoring Studio
(.dmslog8) capture. Each USB OUT transfer is stored as a binary record header
followed by the payload; the header carries a record kind (0x06 = submitted OUT
transfer with data, 0x17 = its completion) and ends with 02 00 00 00 <u32 length>."""
import re,struct,sys
b=open(sys.argv[1],'rb').read()
chunks=[];kinds=set()
for m in re.finditer(rb'\x10\x00\x00\x00(.)\x03\x00\x00.{8}\x02\x00\x00\x00(.{4})',b,re.S):
    L=struct.unpack('<I',m.group(2))[0]
    kinds.add(m.group(1).hex())
    if m.group(1)==b'\x06' and 0<L<=65536: chunks.append(b[m.end():m.end()+L])
stream=b''.join(chunks)
jobs=re.findall(rb'TB\d+,\d+,\d+;CT1;.*?PG!;\r?\n?',stream,re.S)
for i,j in enumerate(jobs):
    toks=[t.strip() for t in j.decode().split(';') if t.strip()]
    bad=[t for t in toks if not re.fullmatch(r'(IN|SP\d|P[UD]-?\d+,-?\d+|PG!|TB\d+,\d+,\d+|CT1)',t)]
    print(f'job {i}: {len(j)} bytes, {len(toks)} commands, invalid={bad[:3]}')
print('record kinds',kinds);print(len(chunks),'transfers,',len(stream),'payload bytes; all jobs identical:',len(set(jobs))==1)
if len(sys.argv)>2: open(sys.argv[2],'wb').write(jobs[0])
