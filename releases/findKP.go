package releases

import (
	"NUMParser/db"
	"NUMParser/db/models"
	"NUMParser/movies/kp"
	"NUMParser/parser"
	"NUMParser/utils"
	"bytes"
	"fmt"
	"github.com/PuerkitoBio/goquery"
	"log"
	"strconv"
	"strings"
	"sync"
)

func FillKP(torrs []*models.TorrentDetails) map[*models.TorrentDetails]*models.KPDetail {
	mlist := map[*models.TorrentDetails]*models.KPDetail{}
	var mu sync.Mutex
	utils.PForLim(torrs, 5, func(i int, t *models.TorrentDetails) {
		kp := FindKPID(t)
		if kp != nil {
			mu.Lock()
			mlist[t] = kp
			mu.Unlock()
		} else {
			kp := FindKP(t)
			if kp != nil {
				mu.Lock()
				mlist[t] = kp
				//log.Println("Find kp:", i+1, "/", len(torrs))
				//if utils.ClearStr(t.Name) != utils.ClearStr(kp.NameRu) || (t.GetNames() != "" && kp.NameEn+kp.NameOriginal != "" && utils.ClearStr(t.GetNames()) != utils.ClearStr(kp.NameEn+kp.NameOriginal)) {
				//	log.Println("Not equal:")
				//	log.Println(t.Name, t.GetNames(), t.Year)
				//	log.Println(kp.NameRu, kp.NameEn+kp.NameOriginal, kp.Year)
				//	log.Println(t.Link)
				//	log.Println(kp.WebURL)
				//}
				mu.Unlock()
			} else {
				log.Println("Not found kp:", t.Name, t.GetNames(), t.Year)
				log.Println(t.Link)
			}
		}
	})
	return mlist
}

func FindKPID(torr *models.TorrentDetails) *models.KPDetail {
	body := parser.GetBodyLink(torr)
	doc, err := goquery.NewDocumentFromReader(bytes.NewBufferString(body))
	if err != nil {
		return nil
	}

	ids := ""

	doc.Find("table#details").Find("a").Each(func(i int, selection *goquery.Selection) {
		if link, ok := selection.Attr("href"); ok {
			if strings.Contains(link, "www.kinopoisk.ru") {
				link = strings.TrimRight(link, "/")
				arr := strings.Split(link, "/")
				if len(arr) > 0 {
					ids = arr[len(arr)-1]
					return
				}
			}
		}
	})
	id, err := strconv.Atoi(ids)
	if err != nil {
		return nil
	}

	kpds := db.GetKPDetails()
	for _, kpd := range kpds {
		if kpd.KinopoiskID == id {
			return kpd
		}
	}

	kp, err := kp.GetDetail(ids)
	if err != nil {
		return nil
	}

	return kp
}

func FindKP(torr *models.TorrentDetails) *models.KPDetail {
	//list := db.SearchKP(torr)
	//if len(list) == 0 {
	//var err error
	query := fmt.Sprint(torr.Name, " ", torr.GetNames(), " ", torr.Year)
	list, err := kp.Search(query)
	if err != nil {
		log.Println("Error search kp:", err)
	}
	list = utils.Filter(list, func(i int, e *models.KPDetail) bool {
		return !utils.IsEqTorrKP(torr, e)
	})
	if len(list) == 0 { // search without year
		list = findKPWY(torr)
		list = utils.Filter(list, func(i int, e *models.KPDetail) bool {
			return !utils.IsEqTorrKP(torr, e)
		})
	}
	//}
	if len(list) > 0 {
		return list[0]
	}
	return nil
}

func findKPWY(torr *models.TorrentDetails) []*models.KPDetail {
	query := fmt.Sprint(torr.Name, " ", torr.GetNames())
	list, err := kp.Search(query)
	if err != nil {
		log.Println("Error search kp:", err)
	}
	list = utils.Filter(list, func(i int, e *models.KPDetail) bool {
		if utils.Abs(e.Year-torr.Year) < 2 {
			return false
		}
		return true
	})
	if len(list) == 0 {
		query = fmt.Sprint(torr.GetNames())
		list, err = kp.Search(query)
		if err != nil {
			log.Println("Error search kp:", err)
		}
		list = utils.Filter(list, func(i int, e *models.KPDetail) bool {
			if utils.Abs(e.Year-torr.Year) < 2 {
				return false
			}
			return true
		})
	}
	if len(list) == 0 {
		query = fmt.Sprint(torr.Name)
		list, err = kp.Search(query)
		if err != nil {
			log.Println("Error search kp:", err)
		}
		list = utils.Filter(list, func(i int, e *models.KPDetail) bool {
			if utils.Abs(e.Year-torr.Year) < 2 {
				return false
			}
			return true
		})
	}

	return list
}
