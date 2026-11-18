// golden writes jingo's output for each shared benchmark payload into tests/golden, so the zig port
// can assert byte-identical output. run from the repo root:
//
//	GO111MODULE=off go run ./tools/golden
package main

import (
	"io"
	"os"
	"path/filepath"
	"strconv"
	"time"

	"jingo"
)

type encode0 struct{ val byte }

func (e *encode0) JSONEncode(w *jingo.Buffer) { w.WriteByte(e.val) }

type encode1 []encode0

func (e *encode1) JSONEncode(w *jingo.Buffer) {
	w.WriteByte('1')
	for _, v := range *e {
		w.WriteByte(v.val)
	}
}

type jsonMarshaler struct{ val []byte }

func (j *jsonMarshaler) EncodeJSON(w io.Writer) { w.Write(j.val) }

type propStruct struct {
	PropNames        []string  `json:"propName"`
	PropPs           []*string `json:"ps"`
	PropNamesEscaped []string  `json:"propNameEscaped,escape"`
}

type all struct {
	PropBool           bool           `json:"propBool"`
	PropInt            int            `json:"propInt"`
	PropInt8           int8           `json:"propInt8"`
	PropInt16          int16          `json:"propInt16"`
	PropInt32          int32          `json:"propInt32"`
	PropInt64          int64          `json:"propInt64"`
	PropUint           uint           `json:"propUint"`
	PropUint8          uint8          `json:"propUint8"`
	PropUint16         uint16         `json:"propUint16"`
	PropUint32         uint32         `json:"propUint32"`
	PropUint64         uint64         `json:"propUint64"`
	PropFloat32        float32        `json:"propFloat32"`
	PropFloat64        float64        `json:"propFloat64,stringer"`
	PropString         string         `json:"propString"`
	PropStruct         propStruct     `json:"propStruct"`
	PropEncode         encode0        `json:"propEncode,encoder"`
	PropEncodeP        *encode0       `json:"propEncodeP,encoder"`
	PropEncodenilP     *encode0       `json:"propEncodenilP,encoder"`
	PropEncodeS        encode1        `json:"propEncodeS,encoder"`
	PropJSONMarshaler  jsonMarshaler  `json:"propJSONMarshaler,encoder"`
	PropJSONMarshalerP *jsonMarshaler `json:"propJSONMarshalerP,encoder"`
}

func newAll(ps []*string) *all {
	return &all{
		PropBool:           false,
		PropInt:            1234567878910111212,
		PropInt8:           123,
		PropInt16:          12349,
		PropInt32:          1234567891,
		PropInt64:          1234567878910111213,
		PropUint:           12345678789101112138,
		PropUint8:          255,
		PropUint16:         12345,
		PropUint32:         1234567891,
		PropUint64:         12345678789101112139,
		PropFloat32:        21.232426,
		PropFloat64:        2799999999888.28293031999999,
		PropString:         "thirty two thirty four",
		PropStruct:         propStruct{[]string{"a name", "another name", "another"}, ps, []string{"one\\two\\,three\"", "\"four\\five\\,six\""}},
		PropEncode:         encode0{'1'},
		PropEncodeP:        &encode0{'2'},
		PropEncodeS:        encode1{encode0{'3'}, encode0{'4'}},
		PropJSONMarshaler:  jsonMarshaler{[]byte("1")},
		PropJSONMarshalerP: &jsonMarshaler{[]byte("2")},
	}
}

type SmallPayload struct {
	St   int    `json:"st"`
	Sid  int    `json:"sid"`
	Tt   string `json:"tt"`
	Gr   int    `json:"gr"`
	UUID string `json:"uuid"`
	IP   string `json:"ip"`
	Ua   string `json:"ua"`
	Tz   int    `json:"tz"`
	V    int    `json:"v"`
}

type DSUser struct {
	Username string `json:"username"`
}

type DSTopic struct {
	ID   int    `json:"ID"`
	Slug string `json:"slug"`
}

type DSTopicsList struct {
	Topics        []*DSTopic `json:"topics"`
	MoreTopicsURL string     `json:"more_topics_URL"`
}

type LargePayload struct {
	Users  []*DSUser     `json:"users"`
	Topics *DSTopicsList `json:"topics"`
}

type UnicodeObject struct {
	Chinese string `json:"chinese"`
	Emoji   string `json:"emoji"`
	Russian string `json:"russian"`
}

type UnicodeObjectLarge struct {
	Chinese string `json:"chinese"`
	Emoji   string `json:"emoji"`
	Russian string `json:"russian"`
	Test    string `json:"test"`
	Test1   string `json:"test1"`
	Test2   string `json:"test2"`
	Test3   string `json:"test3"`
}

type TimeObject struct {
	Time             time.Time    `json:"time"`
	PtrTime          *time.Time   `json:"ptrTime"`
	NullPtrTime      *time.Time   `json:"nullPtrTime"`
	SliceTime        []time.Time  `json:"sliceTime"`
	PtrSliceTime     []*time.Time `json:"ptrSliceTime"`
	NullPtrSliceTime []*time.Time `json:"nullPtrSliceTime"`
}

const filler = "ascdjkl ascdhjklacdshlacdshjkl acdshjcdhjkl acdshjl kacdshjkl acdshjkacdshjklacdhjskl hjkl acdshjkl acdshjkl acdshjkl acdshjkl acdshjkl acdshjk lacdshjk acdshjkl acdshjkl hjkl acdshjkl acdshjkl acdshjkl cdshjkl acdshjkl acdshjkl acdshjkl acdshjkl acdshjkl acdshjkl acdshjkl "

func main() {
	dir := filepath.Join("tests", "golden")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		panic(err)
	}

	write := func(name string, marshal func(*jingo.Buffer)) {
		b := jingo.NewBufferFromPool()
		marshal(b)
		if err := os.WriteFile(filepath.Join(dir, name+".json"), append(b.Bytes, '\n'), 0o644); err != nil {
			panic(err)
		}
		b.ReturnToPool()
	}

	es := "test pointer string"
	write("example", func(b *jingo.Buffer) { jingo.NewStructEncoder(all{}).Marshal(newAll([]*string{&es, nil, &es}), b) })

	fs := "test pointer string b"
	ps := make([]*string, 269)
	for i := range ps {
		if i%2 == 0 {
			ps[i] = &fs
		}
	}
	write("fake", func(b *jingo.Buffer) { jingo.NewStructEncoder(all{}).Marshal(newAll(ps), b) })

	write("small", func(b *jingo.Buffer) {
		jingo.NewStructEncoder(SmallPayload{}).Marshal(&SmallPayload{1, 2, "TestString", 4, "8f9a65eb-4807-4d57-b6e0-bda5d62f1429", "127.0.0.1", "Mozilla", 8, 6}, b)
	})

	lp := &LargePayload{Topics: &DSTopicsList{MoreTopicsURL: "http://test.com"}}
	for i := 0; i < 100; i++ {
		s := "test" + strconv.Itoa(i)
		lp.Users = append(lp.Users, &DSUser{s})
		lp.Topics.Topics = append(lp.Topics.Topics, &DSTopic{i, s})
	}
	write("large", func(b *jingo.Buffer) { jingo.NewStructEncoder(LargePayload{}).Marshal(lp, b) })

	write("unicode", func(b *jingo.Buffer) {
		jingo.NewStructEncoder(UnicodeObject{}).Marshal(&UnicodeObject{"你好，世界", "👋🌍😄😂💊🐂🍺", "ру́сский язы́к"}, b)
	})
	write("unicode_large", func(b *jingo.Buffer) {
		jingo.NewStructEncoder(UnicodeObjectLarge{}).Marshal(&UnicodeObjectLarge{"你好，世界", "👋🌍😄😂👋💊🐂🍺", "ру́сский язы́к", filler, filler, filler, filler}, b)
	})

	d1 := time.Date(2001, 9, 17, 20, 4, 26, 0, time.UTC)
	d3 := time.Date(2003, 9, 17, 20, 4, 26, 0, time.UTC)
	write("time", func(b *jingo.Buffer) {
		jingo.NewStructEncoder(TimeObject{}).Marshal(&TimeObject{
			Time:         time.Date(2000, 9, 17, 20, 4, 26, 0, time.UTC),
			PtrTime:      &d1,
			SliceTime:    []time.Time{time.Date(2002, 9, 17, 20, 4, 26, 0, time.UTC)},
			PtrSliceTime: []*time.Time{&d3},
		}, b)
	})

	ss := []string{"a name", "another name", "another", "and one more", "last one, promise"}
	write("slice", func(b *jingo.Buffer) { jingo.NewSliceEncoder([]string{}).Marshal(&ss, b) })
	write("slice_escape", func(b *jingo.Buffer) { jingo.NewSliceEncoder([]jingo.EscapeString{}).Marshal(&ss, b) })
}
