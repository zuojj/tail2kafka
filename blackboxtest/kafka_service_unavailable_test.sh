#!/bin/bash

BIN="${BASH_SOURCE[0]}"
BINDIR=$(readlink -e $(dirname $BIN))
HOST=$(hostname)

CFGDIR="$BINDIR/tail2kafka"
PIDF=/var/run/tail2kafka.pid
LIBDIR=/var/lib/tail2kafka
BUILDDIR=$BINDIR/../build

if [ ! -d $CFGDIR ]; then
  echo "$CFGDIR NOT FOUND"
  echo "disable autoparti"
  echo "main.lua partition=0"
  echo "main.lua pidfile=$PIDF"
  exit 1
fi

UNBLOCK_KAFKA="iptables -D OUTPUT -p tcp --dport 9092 -j REJECT --reject-with tcp-reset"
BLOCK_KAFKA="iptables -A OUTPUT -p tcp --dport 9092 -j REJECT --reject-with tcp-reset"
echo "UNBLOCK_KAFKA $UNBLOCK_KAFKA"; $UNBLOCK_KAFKA

T2KDIR=logs
test -d $T2KDIR || mkdir $T2KDIR
find $T2KDIR -type f -name "*.log*" -delete

K2FDIR=kafka2filedir
test -d $K2FDIR || mkdir $K2FDIR
find $K2FDIR -type f -delete

# delete.topic.enable=true
TOPIC="basic"
cd /opt/kafka
bin/kafka-topics.sh --delete --zookeeper localhost:2181 --topic $TOPIC
bin/kafka-topics.sh --create --zookeeper localhost:2181 --replication-factor 1 --partitions 1 --topic $TOPIC
cd -

$BUILDDIR/kafka2file 127.0.0.1:9092 basic 0 offset-end kafka2filedir &
KAFKA2FILE_PID=$!
if [ $? != 0 ]; then
  echo "start kafka2file failed"
  exit 1
fi

# prepare history file
rm $LIBDIR/basic.history
for suffix in 2 1; do
  for i in `seq 1 10000`; do
    echo "BASIC_HISTORY_${suffix} $i" >> $T2KDIR/basic.log.history.$suffix
  done
  echo "$T2KDIR/basic.log.history.$suffix" >> $LIBDIR/basic.history
done

rm /var/log/tail2kafka/tail2kafka.log_$(date +%Y-%m-%d)
(test -f $PIDF && test -d /proc/$(cat $PIDF)) && kill $(cat $PIDF); sleep 2
$BUILDDIR/tail2kafka $CFGDIR; sleep 2
if [ ! -f $PIDF ] || [ ! -d /proc/$(cat $PIDF) ]; then
  echo "start tail2kafka failed"
  exit 1;
fi

echo "wait history file be consumed ..."; sleep 30
if [ -f $LIBDIR/basic.history ]; then
  echo "history file should be consumed"
  exit 1
fi

echo "WAIT history file kafka2file ..."; sleep 20
for suffix in 2 1; do
  HISTORYFILE_MD5=$(md5sum $T2KDIR/basic.log.history.$suffix | cut -d' ' -f1)
  K2FFILE_MD5=$(md5sum $K2FDIR/${HOST}_basic.log.history.$suffix | cut -d' ' -f1)
  if [ "$HISTORYFILE_MD5" != "$K2FFILE_MD5" ]; then
    echo "HISTORYFILE $T2KDIR/basic.log.history.$suffix != $K2FDIR/${HOST}_basic.log.history.$suffix"
  exit 1
  fi
done

exit;

echo "BLOCK_KAFKA $BLOCK_KAFKA"; $BLOCK_KAFKA
sleep 1

NFILE=5
NLINE=100000
LOGFILE=$T2KDIR/basic.log
for suffix in `seq $NFILE -1 1`; do
  for i in `seq 1 $NLINE`; do
    echo "BASIC_${suffix} $i" >> $LOGFILE
  done
  mv $LOGFILE $LOGFILE.$suffix
  sleep 120   # rotate interval must > 60

  linenum=$(wc -l $LIBDIR/basic.history | cut -d' ' -f1)
  if [ "$linenum" != $((NFILE+1-suffix)) ]; then
    echo "expect history file number $filenum != $((NFILE+1-suffix))"
    exit 1
  fi

  ofile=$(readlink -e $LOGFILE.$suffix)
  hfile=$(tail -n 1 $LIBDIR/basic.history)
  if [ "$hfile" != "$ofile" ]; then
    echo "except history file $ofile != $hfile"
    exit 1
  fi
done

touch $LOGFILE
$UNBLOCK_KAFKA

echo "WAIT kafka2file ... "; sleep 20
kill $KAFKA2FILE_PID

for suffix in `seq $NFILE -1 1`; do
  ofile=$T2KDIR/basic.log.$suffix
  dfile=$K2FDIR/${HOST}_basic.log.$suffix

  md5Ofile=$(md5sum $ofile | cut -d' ' -f1)
  md5Dfile=$(md5sum $dfile | cut -d' ' -f1)

  if [ "$md5Ofile" != "$md5Dfile" ]; then
    echo "expect $dfile content != $ofile"
    exit 1
  fi
done

echo "OK"

# qsize has bug, if set start, but without tail2kafka, should tail2kafka after init
# kafka2file: src/transform.cc:225: virtual Transform::Idempotent MirrorTransform::write(rd_kafka_message_t*, uint64_t*): Assertion `ide != IGNORE' failed.