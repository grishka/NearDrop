#!/bin/bash

ls ProtobufSource | xargs protoc --swift_out=Protobuf --proto_path=ProtobufSource
