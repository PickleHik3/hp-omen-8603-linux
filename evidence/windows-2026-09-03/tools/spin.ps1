param([int]$Threads=12,[int]$Seconds=60)
Add-Type -TypeDefinition @"
using System; using System.Threading;
public static class Spin {
  public static void Run(int n, double secs){
    var end = DateTime.UtcNow.AddSeconds(secs); var ts = new Thread[n];
    for(int i=0;i<n;i++){ ts[i]=new Thread(()=>{ double x=1.0001; while(DateTime.UtcNow<end){ for(int k=0;k<200000;k++){ x = x*1.0000001+0.5; } } if(x==0) Console.Write(""); }); ts[i].Start(); }
    foreach(var t in ts) t.Join();
  }
}
"@
[Spin]::Run($Threads,$Seconds)
