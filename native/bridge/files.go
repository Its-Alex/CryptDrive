package bridge

import (
	"bytes"
	"context"
	"io"
	"time"

	"github.com/rclone/rclone/fs"
	"github.com/rclone/rclone/fs/accounting"
	"github.com/rclone/rclone/fs/cache"
	"github.com/rclone/rclone/fs/operations"
)

// PutFile writes data to remote inside fsString, e.g. ("vault:", "Photos/a.jpg").
// Progress is reported under statsGroup in core/stats when it is not empty.
func PutFile(ctx context.Context, fsString, remote string, data []byte, statsGroup string) error {
	f, err := cache.Get(ctx, fsString)
	if err != nil {
		return err
	}
	if statsGroup != "" {
		ctx = accounting.WithStatsGroup(ctx, statsGroup)
	}
	_, err = operations.RcatSize(ctx, f, remote, io.NopCloser(bytes.NewReader(data)), int64(len(data)), time.Now(), nil)
	return err
}

// ReadFile reads count bytes of remote from offset; a negative count reads to the end.
func ReadFile(ctx context.Context, fsString, remote string, offset, count int64) (data []byte, err error) {
	f, err := cache.Get(ctx, fsString)
	if err != nil {
		return nil, err
	}
	object, err := f.NewObject(ctx, remote)
	if err != nil {
		return nil, err
	}
	if offset >= object.Size() && object.Size() >= 0 {
		return []byte{}, nil
	}
	end := int64(-1)
	if count >= 0 {
		end = offset + count - 1
	}
	reader, err := object.Open(ctx, &fs.RangeOption{Start: offset, End: end})
	if err != nil {
		return nil, err
	}
	defer fs.CheckClose(reader, &err)
	data, err = io.ReadAll(reader)
	return data, err
}
