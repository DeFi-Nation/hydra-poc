---
sidebar_position: 1
---

# Demo

```mdx-code-block
import DocCardList from '@theme/DocCardList';
import {useCurrentSidebarCategory} from '@docusaurus/theme-common';

<DocCardList items={useCurrentSidebarCategory().items}/>
```

<iframe style={{width: '100%', height: '480px'}} src="https://www.youtube.com/embed/dJk5_kB3BM4" title="Hydra Head Demo" frameborder="0" allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture" allowfullscreen="true"></iframe>

<br/><br/>

:::caution Disclaimer
This video demonstrates a basic terminal user interface for the sake of example. Behind the scene, the terminal client relies on a WebSocket API provided by the Hydra nodes which is what applications will likely be using. Said differently, this is one example of possible application (and to be frank, not a very interesting one!)
:::
