// Decode only the selected demonstration records exported by capture-database.sh.
package main

import (
	"bufio"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"

	ateapi "go.ate.dev/substrate/api/ateapi/v1"
	"google.golang.org/protobuf/encoding/protojson"
	"google.golang.org/protobuf/proto"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run() error {
	var records []map[string]any
	scanner := bufio.NewScanner(os.Stdin)
	scanner.Buffer(make([]byte, 4096), 4<<20)
	for scanner.Scan() {
		var row map[string]any
		if err := json.Unmarshal(scanner.Bytes(), &row); err != nil {
			return err
		}
		raw, ok := row["proto_hex"].(string)
		if !ok {
			return fmt.Errorf("missing proto_hex")
		}
		data, err := hex.DecodeString(raw)
		if err != nil {
			return err
		}
		var message proto.Message
		switch row["kind"] {
		case "Actor":
			message = &ateapi.Actor{}
		case "ActorAssignment":
			message = &ateapi.ActorAssignment{}
		case "Tag":
			message = &ateapi.Tag{}
		default:
			return fmt.Errorf("unsupported kind: %v", row["kind"])
		}
		if err := proto.Unmarshal(data, message); err != nil {
			return err
		}
		decoded, err := protojson.Marshal(message)
		if err != nil {
			return err
		}
		delete(row, "proto_hex")
		row["proto_bytes"] = len(data)
		row["decoded_proto"] = json.RawMessage(decoded)
		records = append(records, row)
	}
	if err := scanner.Err(); err != nil {
		return err
	}
	encoder := json.NewEncoder(os.Stdout)
	encoder.SetIndent("", "  ")
	return encoder.Encode(records)
}
