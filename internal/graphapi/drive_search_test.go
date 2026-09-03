package graphapi

import (
	"context"
	"net/http"
	"reflect"
	"strings"
	"testing"
)

func TestSearchDriveCollectsBoundedPages(t *testing.T) {
	requests := 0
	client := testGraphClient(t, func(req *http.Request) *http.Response {
		requests++
		switch requests {
		case 1:
			if got := req.URL.Path; got != "/v1.0/drives/drive-id/search(q='budget')" {
				t.Errorf("first request path = %q", got)
			}
			if got := req.URL.Query().Get("$top"); got != "3" {
				t.Errorf("first request top = %q, want 3", got)
			}
			return graphJSONResponse(req, `{"value":[{"id":"one","name":"one.docx"},{"id":"two","name":"two.xlsx"}],"@odata.nextLink":"https://graph.microsoft.com/v1.0/drives/drive-id/search(q='budget')?$skiptoken=opaque%20cursor&foo=a%2Bb&$top=3"}`)
		case 2:
			const wantQuery = "$skiptoken=opaque%20cursor&foo=a%2Bb&$top=3"
			if got := req.URL.RawQuery; got != wantQuery {
				t.Errorf("continuation query = %q, want opaque query %q", got, wantQuery)
			}
			return graphJSONResponse(req, `{"value":[{"id":"three","name":"three.pptx"},{"id":"four","name":"four.pdf"}]}`)
		default:
			t.Fatalf("unexpected request %d: %s", requests, req.URL)
			return nil
		}
	})

	items, err := client.SearchDrive(context.Background(), "drive-id", "budget", 3)
	if err != nil {
		t.Fatalf("SearchDrive() error = %v", err)
	}
	if requests != 2 {
		t.Fatalf("request count = %d, want 2", requests)
	}
	got := []string{items[0].ID, items[1].ID, items[2].ID}
	if !reflect.DeepEqual(got, []string{"one", "two", "three"}) {
		t.Errorf("item IDs = %v", got)
	}
}

func TestSearchDriveRejectsUnsafeContinuation(t *testing.T) {
	for _, tc := range []struct {
		name     string
		nextLink string
		want     string
	}{
		{name: "host", nextLink: "https://example.com/v1.0/drives/drive-id/search(q='budget')?$skiptoken=next", want: "unexpected host"},
		{name: "drive", nextLink: "https://graph.microsoft.com/v1.0/drives/other-drive/search(q='budget')?$skiptoken=next", want: "outside expected collection"},
		{name: "query", nextLink: "https://graph.microsoft.com/v1.0/drives/drive-id/search(q='other')?$skiptoken=next", want: "outside expected collection"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			requests := 0
			client := testGraphClient(t, func(req *http.Request) *http.Response {
				requests++
				return graphJSONResponse(req, `{"value":[{"id":"one"}],"@odata.nextLink":"`+tc.nextLink+`"}`)
			})

			items, err := client.SearchDrive(context.Background(), "drive-id", "budget", 2)
			if err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("SearchDrive() error = %v, want %q", err, tc.want)
			}
			if items != nil {
				t.Fatalf("SearchDrive() items = %v, want nil", items)
			}
			if requests != 1 {
				t.Errorf("request count = %d, want 1", requests)
			}
		})
	}
}

func TestSearchDriveRejectsBadPageProgress(t *testing.T) {
	for _, tc := range []struct {
		name       string
		firstBody  string
		secondBody string
		want       string
	}{
		{
			name:      "empty continuation page",
			firstBody: `{"value":[],"@odata.nextLink":"https://graph.microsoft.com/v1.0/drives/drive-id/search(q='budget')?$skiptoken=next"}`,
			want:      "made no progress",
		},
		{
			name:       "duplicate item",
			firstBody:  `{"value":[{"id":"one"}],"@odata.nextLink":"https://graph.microsoft.com/v1.0/drives/drive-id/search(q='budget')?$skiptoken=next"}`,
			secondBody: `{"value":[{"id":"one"}]}`,
			want:       "duplicate item ID",
		},
		{
			name:       "repeated URL",
			firstBody:  `{"value":[{"id":"one"}],"@odata.nextLink":"https://graph.microsoft.com/v1.0/drives/drive-id/search(q='budget')?$skiptoken=next"}`,
			secondBody: `{"value":[{"id":"two"}],"@odata.nextLink":"https://graph.microsoft.com/v1.0/drives/drive-id/search(q='budget')?$skiptoken=next"}`,
			want:       "repeated a previous URL",
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			requests := 0
			client := testGraphClient(t, func(req *http.Request) *http.Response {
				requests++
				body := tc.firstBody
				if requests == 2 {
					body = tc.secondBody
				}
				return graphJSONResponse(req, body)
			})

			items, err := client.SearchDrive(context.Background(), "drive-id", "budget", 3)
			if err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("SearchDrive() error = %v, want %q", err, tc.want)
			}
			if items != nil {
				t.Fatalf("SearchDrive() items = %v, want nil", items)
			}
		})
	}
}
