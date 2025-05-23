package web

import (
	"NUMParser/config"
	"NUMParser/db"
	"github.com/gin-gonic/gin"
	"log"
	"net/http"
)

func setupRouter() *gin.Engine {
	gin.DisableConsoleColor()
	gin.SetMode(gin.ReleaseMode)

	r := gin.New()
	r.Use(gin.Logger(), gin.Recovery())

	// Создаем группу для API Lampac
	lampacGroup := r.Group("/api/lampac")
	// Инициализируем роуты из lampac.go
	InitLampacRoutes(lampacGroup)

	r.Static("/css", "public/css")
	r.Static("/img", "public/img")
	r.Static("/js", "public/js")
	r.StaticFile("/", "public/index.html")

	// http://127.0.0.1:38888/search?query=venom
	r.GET("/search", func(c *gin.Context) {
		if query, ok := c.GetQuery("query"); ok {
			torrs := db.SearchTorr(query)
			c.JSON(200, torrs)
			return
		}
		c.Status(http.StatusBadRequest)
		return
	})
	return r
}

var isSetStatic bool

func SetStaticReleases() {
	if !isSetStatic {
		route.Static("/releases", config.SaveReleasePath)
		isSetStatic = true
	}
}

func Start(port string) {
	route = gin.Default()
	go func() {
		route = setupRouter()
		err := route.Run(":" + port)
		if err != nil {
			log.Println("Error start web server on port", port, ":", err)
		}
	}()
}
