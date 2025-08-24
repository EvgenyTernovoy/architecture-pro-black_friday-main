#!/bin/bash

###
# Инициализируем бд
###

docker compose exec -T config1 mongosh --port 27017 --quiet <<EOF
rs.initiate(
  {
    _id : "configReplSet",
    configsvr: true,
    members: [
      { _id : 0, host : "config1:27017" },
      { _id : 1, host : "config2:27017" },
      { _id : 2, host : "config3:27017" }
    ]
  }
);
exit()
EOF

until docker compose exec -T config1 mongosh --quiet --port 27017 --eval "db.hello().isWritablePrimary" | grep true; do
  echo "Waiting for PRIMARY..."
  sleep 2
done

docker compose exec -T shard1a mongosh --port 27018 --quiet <<EOF
rs.initiate(
    {
      _id : "shard1ReplSet",
      members: [
        { _id : 0, host : "shard1a:27018" },
        { _id : 1, host : "shard1b:27018" },
        { _id : 2, host : "shard1c:27018" }
      ]
    }
);
exit()
EOF

docker compose exec -T shard2a mongosh --port 27018 --quiet <<EOF
rs.initiate(
    {
      _id : "shard2ReplSet",
      members: [
        { _id : 0, host : "shard2a:27018" },
        { _id : 1, host : "shard2b:27018" },
        { _id : 2, host : "shard2c:27018" }
      ]
    }
);
exit()
EOF

docker compose exec -T shard3a mongosh --port 27018 --quiet <<EOF
rs.initiate(
    {
      _id : "shard3ReplSet",
      members: [
        { _id : 0, host : "shard3a:27018" },
        { _id : 1, host : "shard3b:27018" },
        { _id : 2, host : "shard3c:27018" }
      ]
    }
);
exit()
EOF

docker compose exec -T mongos_router mongosh --port 27020 --quiet <<EOF
sh.addShard("shard1ReplSet/shard1a:27018,shard1b:27018,shard1c:27018")
sh.addShard("shard2ReplSet/shard2a:27018,shard2b:27018,shard2c:27018")
sh.addShard("shard3ReplSet/shard3a:27018,shard3b:27018,shard3c:27018")

sh.enableSharding("somedb");
sh.shardCollection("somedb.helloDoc", { "name" : "hashed" } )

use somedb

for(var i = 0; i < 1000; i++) db.helloDoc.insert({age:i, name:"ly"+i})
db.helloDoc.countDocuments() 

db.helloDoc.getShardDistribution()
exit()
EOF
