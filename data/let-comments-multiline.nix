let
  b.a = 3; /*
   this is a multiline comment
   /* we can't nest these comments
  */
  b.c = { e = {}; };
  /* just some more comments
   */
  b.c.e.f = 4;
/* this file is documented really well */
in b /* todo */
