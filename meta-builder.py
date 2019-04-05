#!/usr/bin/python

# 1. .lock is the lock file
# 2. db.json is the result .json file, which keeps
#   - branch & head
#   - build id
#     - status, results, etc.
#   {
#     "build_id": <integer>,
#     "last_commits": {
#        "metadium.github.com:metadium/go-metadium master": "abc...def",
#        "metadium.github.com:metadium/go-metadium metadium": "abc...def"
#     },
#     "builds": {
#       "100": {
#         "start": <time>,
#         "end": <time>,
#         "elapsed": <duration>,
#         "status": success | failure,
#         "error": <string>
#         "init_test": ...,
#         "perf_test": ...,
#       },
#     }
#   }
# 3. testbed.init is the initialization testbed
# 4. testbed.perf is the stress testbed

import distutils.core
import fcntl
import json
import os
import os.path
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time

# constants
lock_name = ".lock"
db_name = "db.json"
testbed_init_name = "testbed.init"
testbed_perf_name = "testbed.perf"
log_dir_name = "logs"
builds_to_keep = 100

# configuration variable
top_dir = "."

def err(*args):
    for i in args:
        sys.stderr.write(i)

def log(*args):
    for i in args:
        sys.stdout.write(i)

def die(en, *args):
    for i in args:
        sys.stderr.write(i)
    sys.stderr.write("\n")
    exit(en)

# [ int returncode, char *out, char *err ] cmd_run(list cmd, char *in=None)
def cmd_run(cmd, in_data=None):
    tf = None
    if in_data:
        tf = tempfile.TemporaryFile()
        tf.write(in_data)
        tf.seek(0, os.SEEK_SET)
    p = subprocess.Popen(cmd, stdin=tf, stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE)
    (o, e) = p.communicate()
    if tf:
        tf.close()
    return [ p.returncode, o, e ]

def cmd_run_tee(cmd):
    def reader(f, buf):
        while True:
            b = f.readline()
            if len(b) == 0:
                break
            sys.stdout.write(b)
            buf.append(b)

    out = []
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    t = threading.Thread(target=reader, args=[p.stdout, out])
    t.start()
    p.wait()
    t.join()
    return [ p.returncode, "".join(out) ]

def strtime():
    return time.strftime("%Y/%m/%d %H:%M:%S")

# db stuff

def db_locked():
    try:
        fn = os.path.join(top_dir, lock_name)
        (rc, out, err) = cmd_run([ "lsof", fn ])
        if rc == 0 and out.find("W ") > 0:
            return True
        else:
            return False
    except:
        return True

def db_lock():
    if db_locked():
        return None
    try:
        f = open(os.path.join(top_dir, lock_name), "w")
        fcntl.lockf(f, fcntl.LOCK_EX)
        return f
    except:
        return None

def db_unlock(f):
    fcntl.lockf(f, fcntl.LOCK_UN)

def db_load():
    try:
        with open(os.path.join(top_dir, db_name), "r") as f:
            return json.load(f)
    except:
        return {}

def db_save(dir, data):
    with open(os.path.join(top_dir, db_name), "w") as f:
        json.dump(data, f, sort_keys=True, indent=4)

def wipe_cluster(dir):
    args = [ "geth/LOCK", "geth/chaindata", "geth/ethash",
             "geth/lightchaindata", "geth/transactions.rlp",
             "geth/nodes", "geth.ipc", "etcd", "logs" ]
    for i in os.listdir(dir):
        n = os.path.join(dir, i)
        if os.path.exists(os.path.join(n, "bin/gmet")) and os.path.exists(os.path.join(n, "geth")) and os.path.exists(os.path.join(n, "conf/genesis-template.json")):
            for j in args:
                shutil.rmtree(os.path.join(n, j), ignore_errors=True)

def upgrade_cluster(dir, tar_file):
    for i in os.listdir(dir):
        n = os.path.join(dir, i)
        if os.path.exists(os.path.join(n, "bin/gmet")) and os.path.exists(os.path.join(n, "geth")) and os.path.exists(os.path.join(n, "conf/genesis-template.json")):
            cmd_run(["tar", "-C", n, "-xf", tar_file])

def cleanup_build_dirs(dir):
    dirs = []
    for i in os.listdir(dir):
        if i.startswith("build."):
            ss = i.split(".")
            if len(ss) == 2:
                dirs.append(ss[1])
    if len(dirs) < builds_to_keep:
        return
    for i in sorted(dirs)[:len(dirs)-builds_to_keep]:
        shutil.rmtree(os.path.join(dir, "build." + str(i)))
    return

def do_init_test(tar_file):
    global top_dir

    first_node = "bob40"
    miner_count = 3
    non_miner_count = 1

    dir = os.path.join(top_dir, testbed_init_name)
    if not os.path.exists(dir):
        os.makedirs(dir, 0755)

    def done():
        log("tearing down docker-compose cluster...\n")
        os.chdir(dir)
        cmd_run_tee(["docker-compose", "down"])

    try:
        log("wiping metadium network...\n")
        wipe_cluster(dir)

        # upgrade cluster if it already exists
        upgrade_cluster(dir, tar_file)

        # setup cluster if not initialized
        if not os.path.exists(os.path.join(dir, "docker-compose.yml")):
            log("setting up docker-compose.yml...\n")
            args = [ os.path.join(top_dir, "bin/bobthe.sh"),
                     "setup-cluster", "-d", dir, "-f", first_node,
                     "-m", str(miner_count), "-n", str(non_miner_count),
                     "-a", tar_file ]
            (rc, out) = cmd_run_tee(args)
            if rc != 0:
                return { "error": str(rc) + ": " + out }

        os.chdir(dir)

        # bring it down, just in case
        (rc, out) = cmd_run_tee(["docker-compose", "down"])

        # bring it up
        log("bringing up docker-compose cluster...\n")
        (rc, out) = cmd_run_tee(["docker-compose", "up", "-d"])
        os.chdir(top_dir)
        if rc != 0:
            return { "error": str(rc) + ": " + out }

        # wait until gmet is up
        log("waiting for gmet in the first node to come up...\n")
        for i in range(0, 301):
            args = [ "docker", "exec", "-it", first_node, "curl", "-s", "http://localhost:8588" ]
            (rc, out) = cmd_run_tee(args)
            if rc == 0:
                break
            if i == 300:
                die(1, "Cannot connect to gmet in " + first_node + ". Check logs.")
            time.sleep(1)

        # wait until system is ready
        log("waiting for all the miners to be up and running...\n")
        base_args = [ "docker", "exec", "-it", first_node, "/opt/meta/bin/gmet",
                      "attach", "ipc:/opt/meta/geth.ipc", "--preload",
                      "/data/rc.js", "--exec" ]
        args = base_args + [ """check_all_miners(300)""" ]
        (rc, out) = cmd_run_tee(args)
        if rc != 0 or out.find("true") == -1:
            die(1, "Governance setup failed. Check logs.")

        # run the basic send test
        log("running the basic send test...\n")
        args = base_args + [ """console.log(JSON.stringify(bulk_send("/opt/meta/keystore/account-01", "password", eth.accounts[1], 1, 1000, 10, false), null, "  "))""" ]
        (rc, out) = cmd_run_tee(args)
        if rc != 0:
            die(1, "Basic send test failed. Check logs.")
        # remove trailing 'undefined'
        try:
            out = json.loads(re.sub(r'}[^}]*$', "}", out))
        except ValueError, e:
            print e
        return out
    finally:
        done()

def do_perf_test(tar_file):
    global top_dir

    first_node = "bob50"
    miner_count = 3
    non_miner_count = 1

    dir = os.path.join(top_dir, testbed_perf_name)
    if not os.path.exists(dir):
        os.makedirs(dir, 0755)

    def done():
        log("tearing down docker-compose cluster...\n")
        os.chdir(dir)
        cmd_run_tee(["docker-compose", "down"])

    try:
        # upgrade cluster if it already exists
        upgrade_cluster(dir, tar_file)

        # setup cluster if not initialized
        if not os.path.exists(os.path.join(dir, "docker-compose.yml")):
            log("setting up docker-compose.yml...\n")
            args = [ os.path.join(top_dir, "bin/bobthe.sh"),
                     "setup-cluster", "-d", dir, "-f", first_node,
                     "-m", str(miner_count), "-n", str(non_miner_count),
                     "-a", tar_file ]
            (rc, out) = cmd_run_tee(args)
            if rc != 0:
                return { "error": str(rc) + ": " + out }

        os.chdir(dir)

        # bring it down, just in case
        (rc, out) = cmd_run_tee(["docker-compose", "down"])

        # bring it up
        log("bringing up docker-compose cluster...\n")
        (rc, out) = cmd_run_tee(["docker-compose", "up", "-d"])
        os.chdir(top_dir)
        if rc != 0:
            return { "error": str(rc) + ": " + out }

        # wait until gmet is up
        log("waiting for gmet in the first node to come up...\n")
        for i in range(0, 301):
            args = [ "docker", "exec", "-it", first_node, "curl", "-s", "http://localhost:8588" ]
            (rc, out) = cmd_run_tee(args)
            if rc == 0:
                break
            if i == 300:
                die(1, "Cannot connect to gmet in " + first_node + ". Check logs.")
            time.sleep(1)

        # wait until system is ready
        log("waiting for all the miners to be up and running...\n")
        base_args = [ "docker", "exec", "-it", first_node, "/opt/meta/bin/gmet",
                      "attach", "ipc:/opt/meta/geth.ipc", "--preload",
                      "/data/rc.js", "--exec" ]
        args = base_args + [ """check_all_miners(300)""" ]
        (rc, out) = cmd_run_tee(args)
        if rc != 0 or out.find("true") == -1:
            die(1, "Governance setup failed. Check logs.")

        # run the basic performance test
        log("running the performance send test...\n")
        args = base_args + [ """console.log(JSON.stringify(bulk_send("/opt/meta/keystore/account-01", "password", eth.accounts[1], 1, 100000, 1000, false), null, "  "))""" ]
        (rc, out) = cmd_run_tee(args)
        if rc != 0:
            die(1, "Performance send test failed. Check logs.")
        # remove trailing 'undefined'
        try:
            out = json.loads(re.sub(r'}[^}]*$', "}", out))
        except ValueError, e:
            print e
        return out
    finally:
        done()

# [ status, init_result, stress_result, error ]
def do_tests(tar_file):
    global top_dir

    # init testing...
    print "init_testing..."
    os.chdir(top_dir)
    r_init = do_init_test(tar_file)

    # stress testing
    print "perf_testing..."
    os.chdir(top_dir)
    #r_perf = do_perf_test(tar_file)
    r_perf = { "error": "not ready yet" }
    return True, r_init, r_perf, None

def check_and_build(dir, repository, branch):
    global top_dir

    start_time = time.time()

    if repository == None or len(repository) == 0:
        die(1, "Repository is not specified")
    if branch == None or len(branch) == 0:
        branch = "master"

    if not os.path.exists(dir):
        die(1, "Cannot locate " + dir)
    top_dir = os.path.realpath(dir)

    lck = db_lock()
    if not lck:
        die(1, "Builidng job is in progrss.")
    data = db_load()

    # clean up old directories
    cleanup_build_dirs(top_dir)

    # set up the directory
    build_id = "build_id" in data and data["build_id"] or 1
    while True:
        build_dir = os.path.join(top_dir, "build.{id}".format(id=build_id))
        if not os.path.exists(os.path.join(dir, ".git")):
            break
        build_id = build_id + 1

    # setup logs directory
    if not os.path.exists(os.path.join(top_dir, "logs")):
        os.makedirs(os.path.join(top_dir, "logs"))

    # get the last commit
    print "getting last commit..."
    last_commit = ""
    if not "last_commits" in data:
        pass
    else:
        id = repository + " " + branch
        last_commit = id in data["last_commits"] and data["last_commits"][id] or ""

    # get the latest commit
    print "getting latest commit..."
    (rc, out, err) = cmd_run([ "git", "ls-remote", "--heads", repository ])
    if rc != 0:
        die(1, "git ls-remote --heads " + repository + " failed: " + out + err)
    latest_commit = ""
    for i in out.splitlines():
        if not i.endswith("refs/heads/" + branch):
            continue
        ls = i.split()
        if len(ls) != 2:
            continue
        latest_commit = ls[0]
    if len(latest_commit) == 0:
        die(1, "Cannot get the latest commit of {repository} {branch}".
            format(repository=repository, branch=branch))
    elif latest_commit == last_commit:
        die(0, "No update on {repository} {branch}. Commit is {commit}".
            format(repository=repository, branch=branch, commit=latest_commit))

    # setup log file, and redirect stdout and stderr
    try:
        logname = os.path.join(top_dir, "logs/build.{id}.log".format(id=build_id))
        print "switching to log file. 'tail -F {logname}' to follow...".format(logname=logname)
        logf = open(logname, "w", 0)
        lnk = os.path.join(top_dir, "log")
        if os.path.exists(lnk):
            os.remove(lnk)
        os.symlink(logname, lnk)
        sys.stdout = logf
        sys.stderr = logf
    except IOError, e:
        die(1, "Cannot create log file {dir}/logs/build.{id}.log: {err}".
            format(dir=top_dir, id=build_id, err=e)
    except:
        die(1, "Cannot create log file {dir}/logs/build.{id}.log: {err}".
            format(dir=top_dir, id=build_id, err=sys.exc_info()[0]))

    # create the directory
    if not os.path.exists(build_dir):
        os.makedirs(build_dir)

    # clone
    print "cloning to " + latest_commit
    if os.path.exists(os.path.join(build_dir, ".git")):
        os.chdir(build_dir)
        (rc, out) = cmd_run_tee([ "git", "pull", "origin", branch ])
        if rc != 0:
            die(1, "git pull origin {branch} failed on {dir}: {out}".
                format(branch=branch, dir=build_dir, out=out))
    else:
        (rc, out) = cmd_run_tee([ "git", "clone", "-b", branch, repository, build_dir ])
        if rc != 0:
            die(1, "git clone -b {branch} {repository} failed on {dir}: {out}".
                format(branch=branch, repository=repository, dir=build_dir, out=out))

    os.chdir(build_dir)
    (rc, out) = cmd_run_tee([ "git", "checkout", latest_commit ])
    if rc != 0:
        die(1, "git checkout {commit} failed: {out}".
            format(commit=latest_commit, out=out))

    # build
    print "building..."
    (rc, out) = cmd_run_tee([ "make", "gmet-linux" ])
    if rc != 0:
        die(1, "make gmet-linux failed: {err}", err)

    # run tests
    (rc, r_init, r_perf, err) = do_tests(os.path.join(build_dir, "build/metadium.tar.gz"))

    # update db
    end_time = time.time()
    dt = int(end_time - start_time)
    data["build_id"] = build_id + 1
    if not "last_commits" in data:
        data["last_commits"] = {}
    data["last_commits"][repository + " " + branch] = latest_commit
    if not "builds" in data:
        data["builds"] = {}
    result = {
        "status": "success",
        "repository": repository,
        "branch": branch,
        "commit": latest_commit,
        "start": time.strftime("%Y/%m/%d %H:%M:%S", time.localtime(start_time)),
        "end": time.strftime("%Y/%m/%d %H:%M:%S", time.localtime(end_time)),
        "elapsed": dt
    }
    result["init_test"] = r_init
    result["perf_test"] = r_perf
    data["builds"][str(build_id)] = result

    log(json.dumps(result, sort_keys=True, indent=4))
    db_save(dir, data)
    db_unlock(lck)
    return True

def run():
    lck = threading.RLock()
    def do_check_and_build(dir, repository, branch):
        if lck.acquire(blocking=False):
            try:
                check_and_build(dir, repository, branch)
            finally:
                lck.release()

    timers = []
    args = [ ".", "metadium.bitbucket.org:/coinplugin/go-metadium", "metadium" ]
    timer.append(threading.Timer(100, do_check_and_build, args=args))
    args = [ ".", "metadium.github.com:/metadium/go-metadium", "master" ]
    timer.append(threading.Timer(300, do_check_and_build, args=args))
    for i in timers:
        i.join()
    return 0

def usage():
    print """Usage: {prog} check-and-build <repository> <branch>
    build-now <repository> [<name>]
    cancel-build
""".format(prog="hello")

def main(args):
    if len(args) <= 1:
        usage()
        exit(1)

    cmd = args[1]
    nargs = args[2:]
    if cmd == "help":
        usage()
        return 0
    elif cmd == "run":
        return run()
    elif cmd == "build":
        # %prog dir repository branch
        if len(nargs) != 3:
            usage()
        else:
            check_and_build(nargs[0], nargs[1], nargs[2])
    elif cmd == "run-tests":
        # %prog dir tar
        if len(nargs) != 2:
            usage()
        else:
            top_dir = nargs[0]
            lck = db_lock()
            try:
                (rc, r_init, r_perf, err) = do_tests(nargs[1])
                print r_init, r_perf
            finally:
                db_unlock(lck)

# it begins...
if __name__ == "__main__":
    exit(main(sys.argv))

# EOF
