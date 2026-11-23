import sys
d=bytes.fromhex(sys.argv[1])
i=0;ind=0
gt={0x04:'UsagePage',0x08:'Usage',0x14:'LogMin',0x24:'LogMax',0x74:'ReportSize',0x94:'ReportCount',0x84:'ReportID',0x18:'UsageMin',0x28:'UsageMax',0x34:'PhysMin',0x44:'PhysMax'}
mt={0x80:'Input',0x90:'Output',0xB0:'Feature',0xA0:'Collection',0xC0:'EndCollection'}
while i<len(d):
    b=d[i];sz=b&3;sz=4 if sz==3 else sz;t=b&0xFC
    v=int.from_bytes(d[i+1:i+1+sz],'little');i+=1+sz
    if t==0xC0: ind-=1
    n=mt.get(t) or gt.get(t) or hex(t)
    print('  '*ind+f'{n} {hex(v)}')
    if t==0xA0: ind+=1
