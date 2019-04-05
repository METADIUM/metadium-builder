// rc.js

var owa = typeof offlineWalletOpen == "function"
var srts = typeof eth.sendRawTransactions == "function"

function unlck(passwd, cnt) {
    if (!cnt || cnt <= 0 || cnt > eth.accounts.length) cnt = eth.accounts.length
    for (var i = 0; i < cnt; i++)
        personal.unlockAccount(eth.accounts[i], passwd, 3600)
}

function miners(to) {
    if (!admin.metadiumInfo || !admin.metadiumInfo.self) {
        console.log("Miner status not available")
        return false
    }

    var x = admin.metadiumNodes("", to);
    var blocks = new Array()
    for (i = 0; i < x.length; i++) {
        var y = x[i], status
        if (y.status == "down")
            status = "x";
        else {
            var bn = y.latestBlockHeight;
            var bh = y.latestBlockHash;
            var ch = blocks["." + bn];
            if (!ch) {
                ch = eth.getBlock(bn);
                if (ch == null)
                    ch = "future";
                else
                    ch = eth.getBlock(bn).hash;
                blocks["." + bn] = ch;
            }
            if (ch == "future")
                status = "o";
            else if (ch == bh)
                status = "O";
            else
                status = "X";
        }
        var name = y.name;
        var miners = y.miningPeers
        console.log(name + "/" + y.id.substr(0,8) + ": " + y.status +
            ", " + y.latestBlockHeight + "/" + y.latestBlockHash.substr(2,8) +
            "/" + status + ", \"" + miners + "\", " + y.rttMs + " ms");
    }
    return true
}

// ix is either positive block number or count in negative
function viewTxs(ix, count) {
    if (!count)
        count = 100000;
    var cur = eth.getBlock('latest').number;
    if (ix < 0) {
        ix = cur + ix;
        lix = ix + count;
    } else {
        lix = ix + count;
    }
    if (lix > cur) lix = cur;
    if (lix < ix) lix = ix;

    for (var i = ix; i <= lix; i++) {
        var b = eth.getBlock(i);
        console.log(i +  ": " + b.transactions.length + ", " + b.timestamp);
    }
    return true
}

// wait for the governance contract to be up, then initialize etcd
function init_etcd(cnt) {
    for (var i = 0; i < cnt; i++) {
        if (admin.metadiumInfo && admin.metadiumInfo.self) {
            if (admin.metadiumInfo.etcd && admin.metadiumInfo.etcd.self)
                return true
            try {
                admin.etcdInit()
            }
            catch (e) {
                console.log(e)
                admin.sleep(1)
                continue
            }
        } else {
            admin.sleep(1)
        }
    }
    return false
}

// wait for all the miners to join etcd
function check_all_miners(cnt) {
    var ln = 0;
    for (var i = 0; i < cnt; i++) {
        if (!admin.metadiumInfo || !admin.metadiumInfo.nodes ||
            !admin.metadiumInfo.etcd || !admin.metadiumInfo.etcd.members) {
            admin.sleep(1)
            continue
        }
        var n1 = admin.metadiumInfo.nodes.length
        var n2 = admin.metadiumInfo.etcd.members.length
        if (ln != n2) {
            ln = n2
            console.log("  miners=" + n1 + " vs. etcd-connected=" + n2)
        }
        if (n1 == n2)
            return true
        else
            admin.sleep(1)
    }
    return false
}

function bulk_send(walletUrl, password, to, value, count, batchSize, verbose) {
    var t = (new Date()).getTime()
    var chainId = eth.chainId(), gasPrice = eth.gasPrice, gas = 100000
    var w, from, nonce, h, good, stxs = new Array()

    if (owa) {
        w = offlineWalletOpen(walletUrl, password)
        from = w.address
    } else {
        w = null
        from = eth.accounts[0]
        personal.unlockAccount(from, password, 36000)
    }
    nonce = eth.getTransactionCount(from, "pending")

    var signTx = function(tx) {
        if (!tx.from) tx.from = from
        if (!tx.gasPrice) tx.gasPrice = gasPrice
        if (!tx.gas) tx.gas = gas
        if (owa) {
            return offlineWalletSignTx(w.id, tx, chainId)
        } else {
            return eth.signTransaction(tx).raw
        }
    }

    var ix = 0;
    while (ix < count) {
        var l = batchSize
        if (ix + l >= count)
            l = count - ix
        stxs.length = 0
        if (verbose)
            console.log("signing " + ix + ", " + l + "...")
        for (var j = 0; j < l; j++) {
            var tx = { from:from, to:to, value:value, gasPrice:gasPrice,
                gas:gas, nonce:nonce++ }
            stxs[j] = signTx(tx)
        }
        if (verbose)
            console.log("sending...")
        if (srts) {
            var hs = eth.sendRawTransactions(stxs)
            h = hs[hs.length - 1]
        } else {
            for (var j = 0; j < l; j++)
                h = eth.sendRawTransaction(stxs[j])
        }
        ix += l
    }

    var dt1 = (new Date()).getTime() - t
    if (dt1 <= 0) dt1 = 1;

    if (verbose)
        console.log("checking the last tx: " + h)

    // check the last transaction receipt
    var cnt = 100, interval = 500
    for (var i = 0; i < cnt; i++) {
        var r = eth.getTransactionReceipt(h)
        if (r != null) {
            good = web3.toBigNumber(r.status) == 1
            break
        }
        msleep(interval)
    }

    var dt2 = (new Date()).getTime() - t
    if (dt2 <= 0) dt2 = 1;

    return { "count": count, "t_send": dt1, "t_confirm": dt2,
             "tps": Math.round(count * 1000 * 1000 / dt2) / 1000.0 }
}

// EOF
