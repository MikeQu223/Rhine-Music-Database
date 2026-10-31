import sys, time
out = sys.stdout
for line in sys.stdin:
    out.write("%d\t%s" % (int(time.time() * 1000), line))
    out.flush()
